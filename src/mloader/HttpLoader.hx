/*
Copyright (c) 2012 Massive Interactive

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

package mloader;

import mloader.Loader;

#if haxe3
import haxe.ds.StringMap;
#else
private typedef StringMap<T> = Hash<T>;
#end

/**
The HttpLoader class is responsible for loading content over Http, falling back
to file system access for local paths under Neko (as haxe.Http does not support
file:/// urls). Data can also be posted to a url using the `send` method, which
automatically detects content-type (unless you set a custom content-type header).
*/
class HttpLoader<T> extends LoaderBase<T>
{
	#if (nme || openfl)
	/**
	The URLLoader used to load content.
	*/
	public var loader:flash.net.URLLoader;

	/**
	The URLRequest to load.
	*/
	var urlRequest:flash.net.URLRequest;
	#else
	/**
	The http instance used to load the content.
	*/
	var http:Http;
	#end

	/**
	The headers to pass through with the http request.
	*/
	public var headers(default, null):StringMap<String>;

	/**
	Http status code of response.
	*/
	public var statusCode(default, null):Int;

	/**
	@param url  the url to load the resource from
	@param http optional Http instance to use for the load request
	*/
	function new(?url:String, ?http:Http)
	{
		super(url);

		headers = new StringMap();

		#if (nme || openfl)
		urlRequest = new flash.net.URLRequest();
		loader = new flash.net.URLLoader();

		loader.addEventListener(flash.events.HTTPStatusEvent.HTTP_STATUS, loaderEvent);
		loader.addEventListener(flash.events.Event.COMPLETE, loaderEvent);
		loader.addEventListener(flash.events.IOErrorEvent.IO_ERROR, loaderEvent);
		loader.addEventListener(flash.events.SecurityErrorEvent.SECURITY_ERROR, loaderEvent);
		#else
		if (http == null) http = new Http("");

		this.http = http;
		http.onData = httpData;
		http.onError = httpError;
		http.onStatus = httpStatus;
		#end
	}

	#if (sys && !openfl)
	/**
	Local urls are loaded from the file system in neko or cpp.
	*/
	function loadFromFileSystem(url:String)
	{
		if (!sys.FileSystem.exists(url))
		{
			loaderFail(IO("Local file does not exist: " + url));
		}
		else
		{
			var contents = sys.io.File.getContent(url);
			httpData(contents);
		}
	}
	#end

	#if (nodejs)
	/**
	Local urls are loaded from the file system in nodejs.
	*/
	function loadFromFileSystem(url:String)
	{
		if (!js.node.Fs.existsSync(url))
		{
			loaderFail(IO("Local file does not exist: " + url));
		}
		else
		{
			var contents = js.node.Fs.readFileSync(url).toString();
			httpData(contents);
		}
	}
	#end

	/**
	Configures and makes the http request. The send method can also pass
	through data with the request. It also traps any security errors and
	dispatches a failed signal.

	@param url The url to load.
	@param data Data to post to the url.
	*/
	public function send(data:Dynamic)
	{
		// if currently loading, cancel
		if (loading) cancel();

		// if no url, throw exception
		if (url == null) throw "No url defined for Loader";

		// update state
		loading = true;

		// dispatch started
		loaded.dispatchType(Start);

		// default content type
		var contentType = "application/octet-stream";

		if (Std.is(data, Xml))
		{
			// convert to string and send as application/xml
			data = Std.string(data);
			contentType = "application/xml";
		}
		else if (!Std.is(data, String))
		{
			// stringify and send as application/json
			data = haxe.Json.stringify(data);
			contentType = "application/json";
		}
		else if (Std.is(data, String) && validateJSONdata(data))
		{
			//data is already a valid JSON string
			contentType = "application/json";
		}

		#if openfl
		//OpenFL Native targets cannot set the Content-Type directly in the headers
		urlRequest.contentType = contentType;
		#else
		// only set content type if not already set
		if (!headers.exists("Content-Type"))
		{
			headers.set("Content-Type", contentType);
		}
		#end

		httpConfigure();
		addHeaders();

		#if (nme || openfl)
		urlRequest.url = url;
		urlRequest.method = flash.net.URLRequestMethod.POST;
		urlRequest.data = data;
		loader.load(urlRequest);
		#else
		http.url = url;
		http.setPostData(data);

		try
		{
			http.request(true);
		}
		catch (e:Dynamic)
		{
			// js can throw synchronous security error
			loaderFail(Security(Std.string(e)));
		}
		#else
		#end
	}

	//-------------------------------------------------------------------------- private

	override function loaderLoad()
	{
		httpConfigure();
		addHeaders();

		#if (nme || openfl)
		urlRequest.url = url;
		if (url.indexOf("http:") == 0 || url.indexOf("https:") == 0)
		{
			loader.load(urlRequest);
		}
		else
		{
			#if openfl
			var result = openfl.Assets.getText(url);
			#else
			var result = nme.installer.Assets.getBitmapData(url);
			#end

			#if haxe3
			haxe.Timer.delay(httpData.bind(result), 10);
			#else
			haxe.Timer.delay(callback(httpData, result), 10);
			#end
		}
		#else
		http.url = url;
		#if (sys || nodejs)
		if (url.indexOf("http:") == 0 || url.indexOf("https:") == 0)
		{
			http.request(false);
		}
		else
		{
			loadFromFileSystem(url);
		}
		#else
		try
		{
			http.request(false);
		}
		catch (e:Dynamic)
		{
			// js can throw synchronous security error
			loaderFail(Security(Std.string(e)));
		}
		#end
		#end
	}

	override function loaderCancel():Void
	{
		#if (nme || openfl)
		try { loader.close(); } catch(e:Dynamic) {}
		#elseif !sys
		http.cancel();
		#end
	}

	function httpConfigure()
	{
		// abstract
	}

	function addHeaders()
	{
		#if (nme || openfl)
		var requestHeaders = [];
		for (name in headers.keys())
		{
			requestHeaders.push(new flash.net.URLRequestHeader(name, headers.get(name)));
		}
		urlRequest.requestHeaders = requestHeaders;
		#else
		for (name in headers.keys())
		{
			http.setHeader(name, headers.get(name));
		}
		#end
	}

	function httpData(data:String)
	{
		content = cast data;
		loaderComplete();
	}

	function httpStatus(status:Int)
	{
		statusCode = status;
	}

	function httpError(error:String)
	{
		#if !openfl
		content = cast http.responseData;
		#end
		loaderFail(IO(error));
	}

	function httpSecurityError(error:String)
	{
		loaderFail(Security(error));
	}

	function validateJSONdata(data:String):Bool
	{
		var isValid:Bool = true;

		try { haxe.Json.parse(data); }
		catch (error:Dynamic) { isValid = false; }

		return isValid;
	}

	#if (nme || openfl)

	function loaderEvent(e:Dynamic)
	{
		switch (e.type)
		{
			case flash.events.HTTPStatusEvent.HTTP_STATUS:
			httpStatus(e.status);

			case flash.events.Event.COMPLETE:
			httpData(Std.string(e.target.data));

			case flash.events.IOErrorEvent.IO_ERROR:
			httpError(Std.string(e));

			case flash.events.SecurityErrorEvent.SECURITY_ERROR:
			httpSecurityError(Std.string(e));
		}
	}

	#end
}
