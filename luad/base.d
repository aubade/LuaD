module luad.base;

import luad.c.all;
import luad.stack;

import core.stdc.string : strlen;


// shall we declare the attributes here?
struct noscript {}


/**
 * Enumerates all Lua types.
 */
enum LuaType
{
	///string
	String = LUA_TSTRING,
	///number
	Number = LUA_TNUMBER,
	//table
	Table = LUA_TTABLE,
	///nil
	Nil = LUA_TNIL,
	///boolean
	Boolean = LUA_TBOOLEAN,
	///function
	Function = LUA_TFUNCTION,
	///userdata
	Userdata = LUA_TUSERDATA,
	///ditto
	LightUserdata = LUA_TLIGHTUSERDATA,
	///thread
	Thread = LUA_TTHREAD
}

package struct Nil{}

/**
 * Special value representing the Lua type and value nil.
 * Examples:
 * Useful for clearing keys in a table:
 * --------------------------
	lua["n"] = 1.23;
	assert(lua.get!double("n") == 1.23);

	lua["n"] = nil;
	assert(lua["n"].type == LuaType.Nil);
 * --------------------------
 */
public Nil nil;

/**
 * Represents a reference to a Lua value of any type.
 * It contains only the bare minimum of functionality which all Lua values support.
 * For a generic reference type with more functionality, see $(DPREF dynamic,LuaDynamic).
 */
struct LuaObject
{
	__gshared static bool quitting = false;
	private:
	int r = LUA_REFNIL;
	lua_State* L = null;

	package:
	this(lua_State* L, int idx)
	{
		this.L = L;

		lua_pushvalue(L, idx);
		r = luaL_ref(L, LUA_REGISTRYINDEX);
	}

	public void push() nothrow
	{
		lua_rawgeti(L, LUA_REGISTRYINDEX, r);
	}

	static void checkType(lua_State* L, int idx, int expectedType, const(char)* expectedName)
	{
		int t = lua_type(L, idx);
		if(t != expectedType)
		{
			luaL_error(L, "attempt to create %s with %s", expectedName, lua_typename(L, t));
		}
	}

	public:
	@trusted this(this)
	{
		if (L is null) return;
		push();
		r = luaL_ref(L, LUA_REGISTRYINDEX);
	}

	@trusted nothrow ~this()
	{
		if (L is null || r == LUA_REFNIL || quitting) return;
		luaL_unref(L, LUA_REGISTRYINDEX, r);
		release();
	}

	/// The underlying $(D lua_State) pointer for interfacing with C.
	lua_State* state() pure nothrow @safe @property
	{
		return L;
	}

	/**
	 * Release this reference.
	 *
	 * This reference becomes a nil reference.
	 * This is only required when you want to _release the reference before the lifetime
	 * of this $(D LuaObject) has ended.
	 */
	void release() pure nothrow @safe
	{
		r = LUA_REFNIL;
		L = null;
	}

	/**
	 * Type of referenced object.
	 * See_Also:
	 *	 $(MREF LuaType)
	 */
	@property LuaType type() @trusted nothrow
	{
		if (state is null) return LuaType.Nil;
		push();
		auto result = cast(LuaType)lua_type(state, -1);
		lua_pop(state, 1);
		return result;
	}

	/**
	 * Type name of referenced object.
	 */
	@property string typeName() @trusted /+ nothrow +/
	{
		import std.exception;
		if (state is null) return "nil";
		push();
		if (lua_type(state, -1) == LuaType.Userdata) {
			if (lua_getmetatable(L, -1)) {
				pushValue(L, "__dtype");
				lua_gettable(L, -2);
				if (!lua_isnil(L, -1) && lua_type(L, -1) == LuaType.String) {
					size_t len;
					const(char)* cname = lua_tolstring(L, -1, &len);
					auto name = assumeUnique(cname[0..len]);
					lua_pop(state, 1);
					return name;
				}
			}
		}
		const(char)* cname = luaL_typename(state, -1); // TODO: Doesn't have to use luaL_typename, i.e. no copy
		auto name = assumeUnique(cname[0.. strlen(cname)]);
		lua_pop(state, 1);
		return name;
	}

	/// Boolean whether or not the referenced object is nil.
	@property bool isNil() pure nothrow @safe
	{
		return r == LUA_REFNIL;
	}

	/**
	 * Convert the referenced object into a textual representation.
	 *
	 * The returned string is formatted in the same way the Lua $(D tostring) function formats.
	 *
	 * Returns:
	 * String representation of referenced object
	 */
	string toString() @trusted
	{
		if (state is null) return "Nil";
		push();

		size_t len;
		const(char)* cstr = luaL_tolstring(state, -1, &len);
		auto str = cstr[0 .. len].idup;

		lua_pop(state, 2);
		return str;
	}

	auto toVString() {
		import luad.conversions.helpers;

		if (state is null) return VolatileString("Nil");
		push();

		size_t len;
		const(char)* cstr = luaL_tolstring(state, -1, &len);
		auto str = VolatileString(cstr[0 .. len]);

		lua_pop(state, 2);
		return str;
	}

	/**
	 * Attempt _to convert the referenced object _to the specified D type.
	 * Examples:
	 -----------------------
	auto results = lua.doString(`return "hello!"`);
	assert(results[0].to!string() == "hello!");
	 -----------------------
	 */
	T to(T)()
	{
		static void typeMismatch(lua_State* L, int t, int e)
		{
			luaL_error(L, "attempt to convert LuaObject with type %s to a %s", lua_typename(L, t), lua_typename(L, e));
		}

		push();
		return popValue!(T, typeMismatch)(state);
	}

	/**
	 * Compare this object to another with Lua's equality semantics.
	 * Also returns false if the two objects are in different Lua states.
	 */
	bool opEquals(T : LuaObject)(ref T o) @trusted
	{
		if(state is null || o.state is null || o.state != this.state)
			return false;

		push();
		o.push();
		scope(success) lua_pop(state, 2);

		return lua_equal(state, -1, -2);
	}
}

void releaseAll (LuaObject[] arr) {
	foreach (ref i; arr) {
		destroy(i);
		i.release();
	}
}

public struct VolatileString {
	const(char)[] str;

	alias str this;
}

public struct Ref(T)
{
	alias __instance this;

	this(ref T s) { ptr = &s; }

	@property ref T __instance() { return *ptr; }

//private:
	T* ptr;
}

public auto makeRef (T)(ref T val) {
	return Ref!T(val);
}

public auto makeRefPtr (T)(T* val) {
	Ref!T retval;
	retval.ptr = val;

	return retval;
}

unittest
{
	lua_State* L = luaL_newstate();
	scope(success) lua_close(L);

	lua_pushstring(L, "foobar");
	auto o = popValue!LuaObject(L);

	assert(!o.isNil);
	assert(o.type == LuaType.String);
	assert(o.typeName == "string");
	assert(o.to!string() == "foobar");

	lua_pushnil(L);
	auto nilref = popValue!LuaObject(L);

	assert(nilref.isNil);
	assert(nilref.typeName == "nil");

	assert(o != nilref);

	auto o2 = o;
	assert(o2 == o);
}
