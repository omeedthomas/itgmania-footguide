// Runs a Lua test script under fengari (Lua VM in JS) so the solver can be
// exercised without launching ITGmania.
//   node test/run.js <script.lua> [args...]
// The Lua script gets globals: ARGS (table of strings), READ(path) -> string|nil,
// LISTDIR(path) -> table of names, CLOCK() -> seconds.
const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require(
  require.resolve("fengari", { paths: [process.env.FENGARI_PATH || process.cwd()] })
);

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function pushFn(name, fn) {
  lua.lua_pushjsfunction(L, fn);
  lua.lua_setglobal(L, to_luastring(name));
}

pushFn("READ", (L) => {
  const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
  try {
    lua.lua_pushstring(L, to_luastring(fs.readFileSync(p, "latin1"), true));
  } catch (e) {
    lua.lua_pushnil(L);
  }
  return 1;
});
pushFn("LISTDIR", (L) => {
  const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
  lua.lua_newtable(L);
  let entries = [];
  try { entries = fs.readdirSync(p); } catch (e) {}
  entries.forEach((name, i) => {
    lua.lua_pushstring(L, to_luastring(name));
    lua.lua_rawseti(L, -2, i + 1);
  });
  return 1;
});
pushFn("CLOCK", (L) => {
  lua.lua_pushnumber(L, performance.now() / 1000);
  return 1;
});

const [script, ...args] = process.argv.slice(2);
lua.lua_newtable(L);
args.forEach((a, i) => {
  lua.lua_pushstring(L, to_luastring(a));
  lua.lua_rawseti(L, -2, i + 1);
});
lua.lua_setglobal(L, to_luastring("ARGS"));
// ROOT is the mod/ folder, laid out like the Simply Love theme folder.
lua.lua_pushstring(L, to_luastring(path.resolve(__dirname, "..", "mod").replace(/\\/g, "/") + "/"));
lua.lua_setglobal(L, to_luastring("ROOT"));

const src = fs.readFileSync(script);
if (lauxlib.luaL_loadbuffer(L, src, null, to_luastring("@" + script)) !== lua.LUA_OK ||
    lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}
