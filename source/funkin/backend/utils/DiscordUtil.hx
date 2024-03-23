package funkin.backend.utils;

import funkin.backend.scripting.events.DiscordPresenceUpdateEvent;
import funkin.backend.scripting.events.CancellableEvent;
import funkin.backend.scripting.*; // lazy
import flixel.util.typeLimit.OneOfTwo;
import openfl.display.BitmapData;
import funkin.backend.system.macros.Utils;
import haxe.Json;
import flixel.sound.FlxSound;
#if DISCORD_RPC
import hxdiscord_rpc.Discord;
import hxdiscord_rpc.Types;
import sys.thread.Thread;
import Sys;
import lime.app.Application;
#end

class DiscordUtil
{
	public static var currentID(default, set):String = null;
	public static var discordThread:#if DISCORD_RPC Thread #else Dynamic #end = null;
	public static var ready:Bool = false;
	private static var stopThread:Bool = false;

	public static var user:#if DISCORD_RPC DUser #else Dynamic #end = null;
	public static var lastPresence:#if DISCORD_RPC DPresence #else Dynamic #end = null;
	public static var events:#if DISCORD_RPC DEvents #else Dynamic #end = null;
	public static var config:#if DISCORD_RPC DiscordJson #else Dynamic #end = null;

	public static var scripts:ScriptPack;

	public static function init()
	{
		#if DISCORD_RPC
		events = {};
		reloadJsonData();

		discordThread = Thread.create(function()
		{
			while (true)
			{
				while (!stopThread)
				{
					#if DISCORD_DISABLE_IO_THREAD
					Discord.UpdateConnection();
					#end
					Discord.RunCallbacks();

					Sys.sleep(2);
				}

				Sys.sleep(1); // to reduce cpu
			}
		});

		Application.current.onExit.add(function(_) shutdown());
		#end
	}

	public static function reloadJsonData()
	{
		#if DISCORD_RPC
		var jsonPath = Paths.json("config/discord");
		if (Assets.exists(jsonPath))
		{
			try
				config = Json.parse(Assets.getText(jsonPath))
			catch (e)
				Logs.trace('Couldn\'t load Discord RPC configuration: ${e.toString()}', ERROR);
		}
		else
		{
			config = {};
		}

		config.logoKey = config.logoKey.getDefault("icon");
		config.logoText = config.logoText.getDefault(Application.current.meta.get('title'));
		config.clientID = config.clientID.getDefault("1027994136193810442");
		currentID = config.clientID;
		#end
	}

	public static function event<T:CancellableEvent>(name:String, event:T):T
	{
		if (scripts != null)
			scripts.event(name, event);
		return event;
	}

	public static function call(name:String, ?args:Array<Dynamic>)
	{
		if (scripts != null)
			scripts.call(name, args);
	}

	public static function loadScript()
	{
		if(scripts != null) {
			call("destroy");
			scripts = FlxDestroyUtil.destroy(scripts);
		}
		scripts = new ScriptPack("DiscordScript");
		for (i in funkin.backend.assets.ModsFolder.getLoadedMods())
		{
			var path = Paths.script('data/discord/LIB_$i');
			var script = Script.create(path);
			if (script is DummyScript)
				continue;

			script.remappedNames.set(script.fileName, '$i:${script.fileName}');
			scripts.add(script);
			script.load();
		}
	}

	public static function changePresence(details:String, state:String, ?smallImageKey:String)
	{
		#if DISCORD_RPC
		changePresenceAdvanced({
			state: state,
			details: details,
			smallImageKey: smallImageKey
		});
		#end
	}

	public static function changeSongPresence(details:String, state:String, audio:FlxSound, ?smallImageKey:String)
	{
		#if DISCORD_RPC
		var start:Float = 0;
		var end:Float = 0;

		if (audio != null && audio.playing)
		{
			start = Date.now().getTime();
			end = start + (audio.length - audio.time);
		}

		changePresenceAdvanced({
			state: state,
			details: details,
			smallImageKey: smallImageKey,
			startTimestamp: Std.int(start / 1000),
			endTimestamp: Std.int(end / 1000)
		});
		#end
	}

	@:noCompletion public static function fixString(str:String)
	{
		return new cpp.ConstCharStar(cast(str, String));
	}

	@:noCompletion public static function toString(str:cpp.ConstCharStar)
	{
		return cast(str, String);
	}

	public static function changePresenceAdvanced(data:DPresence)
	{
		#if DISCORD_RPC
		if (data == null)
			return;

		// copy last presence
		if (data.largeImageKey == null)
			data.largeImageKey = config.logoKey;
		if (data.largeImageText == null)
			data.largeImageText = config.logoText;

		var evt = EventManager.get(DiscordPresenceUpdateEvent).recycle(data);
		#if GLOBAL_SCRIPT
		// kept for "backwards compat"
		funkin.backend.scripting.GlobalScript.event("onDiscordPresenceUpdate", evt);
		#end
		event("onDiscordPresenceUpdate", evt);
		if (evt.cancelled)
			return;
		data = evt.presence;
		lastPresence = data;

		var dp:DiscordRichPresence = DiscordRichPresence.create();
		// TODO: make this use a reflection-like macro
		Utils.safeSetWrapper(dp.state, data.state, fixString);
		Utils.safeSetWrapper(dp.details, data.details, fixString);
		Utils.safeSet(dp.startTimestamp, data.startTimestamp);
		Utils.safeSet(dp.endTimestamp, data.endTimestamp);
		Utils.safeSetWrapper(dp.largeImageKey, data.largeImageKey, fixString);
		Utils.safeSetWrapper(dp.largeImageText, data.largeImageText, fixString);
		Utils.safeSetWrapper(dp.smallImageKey, data.smallImageKey, fixString);
		Utils.safeSetWrapper(dp.smallImageText, data.smallImageText, fixString);
		Utils.safeSetWrapper(dp.partyId, data.partyId, fixString);
		Utils.safeSet(dp.partySize, data.partySize);
		Utils.safeSet(dp.partyMax, data.partyMax);
		Utils.safeSet(dp.partyPrivacy, data.partyPrivacy);
		Utils.safeSetWrapper(dp.matchSecret, data.matchSecret, fixString);
		Utils.safeSetWrapper(dp.joinSecret, data.joinSecret, fixString);
		Utils.safeSetWrapper(dp.spectateSecret, data.spectateSecret, fixString);
		Utils.safeSet(dp.instance, data.instance);

		Discord.UpdatePresence(cpp.RawConstPointer.addressOf(dp));
		#end
	}

	private static function set_currentID(id:String):String
	{
		if (currentID == id)
			return id;
		#if DISCORD_RPC
		if (currentID != null)
			shutdown();

		var handlers:DiscordEventHandlers = DiscordEventHandlers.create();
		handlers.ready = cpp.Function.fromStaticFunction(onReady);
		handlers.disconnected = cpp.Function.fromStaticFunction(onDisconnected);
		handlers.errored = cpp.Function.fromStaticFunction(onError);
		handlers.joinGame = cpp.Function.fromStaticFunction(onJoin);
		handlers.joinRequest = cpp.Function.fromStaticFunction(onJoinReq);
		handlers.spectateGame = cpp.Function.fromStaticFunction(onSpectate);
		Discord.Initialize(id, cpp.RawPointer.addressOf(handlers), 1, null);
		stopThread = false;

		loadScript();
		#end

		return currentID = id;
	}

	public static function shutdown()
	{
		ready = false;
		stopThread = true;
		#if DISCORD_RPC
		Discord.Shutdown();
		#end

		call("destroy");
		scripts = FlxDestroyUtil.destroy(scripts);
	}

	// HANDLERS
	#if DISCORD_RPC
	private static function onReady(request:cpp.RawConstPointer<DiscordUser>):Void
	{
		user = DUser.initRaw(request);

		Logs.traceColored([
			Logs.logText("[Discord] ", BLUE),
			Logs.logText("Connected to User ("),
			Logs.logText(user.tag, GRAY),
			Logs.logText(")")
		], INFO);

		ready = true;

		// if(events.ready != null) events.ready(user);
		call("onReady", [user]);
	}

	private static function onDisconnected(errorCode:Int, message:cpp.ConstCharStar):Void
	{
		var finalMsg:String = cast(message, String);

		Logs.traceColored([
			Logs.logText("[Discord] ", BLUE),
			Logs.logText("Disconnected ("),
			Logs.logText('$errorCode: $finalMsg', RED),
			Logs.logText(")")
		], INFO);

		if (events.disconnected != null)
			events.disconnected(errorCode, finalMsg);

		call("onReady", [errorCode, cast(finalMsg, String)]);
	}

	private static function onError(errorCode:Int, message:cpp.ConstCharStar):Void
	{
		var finalMsg:String = cast(message, String);

		Logs.traceColored([
			Logs.logText("[Discord] ", BLUE),
			Logs.logText("Error ("),
			Logs.logText('$errorCode: $finalMsg', RED),
			Logs.logText(")")
		], ERROR);

		if (events.errored != null)
			events.errored(errorCode, finalMsg);

		call("onError", [errorCode, cast(finalMsg, String)]);
	}

	private static function onJoin(joinSecret:cpp.ConstCharStar):Void
	{
		Logs.traceColored([Logs.logText("[Discord] ", BLUE), Logs.logText("Someone has just joined", GREEN)], INFO);

		if (events.joinGame != null)
			events.joinGame(cast(joinSecret, String));

		call("onJoinGame", [cast(joinSecret, String)]);
	}

	private static function onSpectate(spectateSecret:cpp.ConstCharStar):Void
	{
		Logs.traceColored([
			Logs.logText("[Discord] ", BLUE),
			Logs.logText("Someone started spectating your game", YELLOW)
		], INFO);

		if (events.spectateGame != null)
			events.spectateGame(cast(spectateSecret, String));

		call("onJoinGame", [cast(spectateSecret, String)]);
	}

	private static function onJoinReq(request:cpp.RawConstPointer<DiscordUser>):Void
	{
		Logs.traceColored([
			Logs.logText("[Discord] ", BLUE),
			Logs.logText("Someone has just requested to join", YELLOW)
		], WARNING);

		var req:DUser = DUser.initRaw(request);
		if (events.joinRequest != null)
			events.joinRequest(req);

		call("onJoinRequest", [req]);
	}
	#end
}

typedef DiscordJson =
{
	var ?clientID:String;
	var ?logoKey:String;
	var ?logoText:String;
}

@:noCustomClass
final class DUser
{
	/**
	 * The username + discriminator if they have it
	**/
	public var tag:String;

	/**
	 * The user id, aka 860561967383445535
	**/
	public var userId:String;

	/**
	 * The user's username
	**/
	public var username:String;

	/**
	 * The #number from before discord changed to usernames only, if the user has changed to a username them its just a 0
	**/
	public var discriminator:Int;

	/**
	 * The user's avatar filename
	**/
	public var avatar:String;

	private function new()
	{
	}

	public static function initRaw(req:cpp.RawConstPointer<DiscordUser>)
	{
		return init(cpp.ConstPointer.fromRaw(req).ptr);
	}

	public static function init(userData:cpp.Star<DiscordUser>)
	{
		var d = new DUser();
		d.userId = userData.userId;
		d.username = userData.username;
		d.discriminator = Std.parseInt(userData.discriminator);
		d.avatar = userData.avatar;

		if (d.discriminator != 0)
			d.tag = '${d.username}#${d.discriminator}';
		else
			d.tag = '${d.username}';
		return d;
	}

	/**
	 * Calling this function gets the BitmapData of the user
	**/
	public function getAvatar(size:Int = 256):BitmapData
		return BitmapData.fromBytes(HttpUtil.requestBytes('https://cdn.discordapp.com/avatars/$userId/$avatar.png?size=$size'));
}

typedef DPresence =
{
	var ?state:String; /* max 128 bytes */
	var ?details:String; /* max 128 bytes */
	var ?startTimestamp:OneOfTwo<Int, haxe.Int64>;
	var ?endTimestamp:OneOfTwo<Int, haxe.Int64>;
	var ?largeImageKey:String; /* max 32 bytes */
	var ?largeImageText:String; /* max 128 bytes */
	var ?smallImageKey:String; /* max 32 bytes */
	var ?smallImageText:String; /* max 128 bytes */
	var ?partyId:String; /* max 128 bytes */
	var ?partySize:Int;
	var ?partyMax:Int;
	var ?partyPrivacy:Int;
	var ?matchSecret:String; /* max 128 bytes */
	var ?joinSecret:String; /* max 128 bytes */
	var ?spectateSecret:String; /* max 128 bytes */
	var ?instance:OneOfTwo<Int, cpp.Int8>;
}

typedef DEvents =
{
	var ?ready:DUser->Void;
	var ?disconnected:(errorCode:Int, message:String) -> Void;
	var ?errored:(errorCode:Int, message:String) -> Void;
	var ?joinGame:String->Void;
	var ?spectateGame:String->Void;
	var ?joinRequest:DUser->Void;
}
