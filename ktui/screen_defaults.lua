-- Default HTML for the experimental screens (the files written by
-- "enable"): full UIDSL documents - the <sheet> blocks reuse the engine
-- verb. Text goes through <htmlblock> islands ONLY where rich markdown
-- matters (chat bubbles); everything else stays native-canvas nodes.
-- These are DEFAULTS: the user's themes/screens/<name>.html, once installed,
-- is fully user-owned (device editor or USB).

local Defaults = {}

-- ---------------- Dashboard port (v1) --------------------------------------
-- Cards grid uses the NATIVE dashboard_items action catalog (dash:open,
-- dash:fav). Layout mirrors the native grid: toolbar pills + 3-col cards
-- with cover art via <img>, name + tags + meta.
Defaults.dashboard = [[
<style>
page { background: gray(0.04); }
.row-toolbar { gap: 8px; }
.card { border: true; border-size: 1px; border-color: gray(0.25);
  background: gray(0); radius: 8px; pad: 0px; gap: 0px; }
.card .name { font-size: 16px; bold: true; }
.card .tags { color: gray(0.45); font-size: 12px; }
.card .meta { color: gray(0.45); font-size: 11px; }
</style>
<div class="card">
  <p class="center muted">Tela experimental: dashboard em UIDSL.</p>
  <p class="muted">Os cards aparecem aqui pelo catálogo dash:cards
  (componente slot). Edite este HTML em Debug > Experimental.</p>
  <row>
    <button data-action="dash:search">Buscar</button>
    <button data-action="dash:import">Importar</button>
  </row>
</div>
]]

-- ---------------- Chat port (v1) --------------------------------------------
-- HUD: title bar handled by the native header (the port paints INSIDE the
-- content area). The message stream is a chat:messages SLOT - the engine
-- paints the native bubble list there (streaming + holds + swipes keep
-- their native behavior); bubbles draw their rich text via KtHTML islands.
-- LAYOUT MIRRORS THE NATIVE CHAT (Pages.chat): the slot is a flex=10 filler
-- (measured ~0 tall, expands at paint time to fill everything ABOVE the
-- composer), the composer is a full-border-zero row with a flex=3 textarea
-- + flex=1 Enviar (kind=primary, Exchange-like), and the bottom row is the
-- ST action bar (Continuar / Opcoes) with halign between (dividers come
-- from the engine's painted sheet-shape, not a fake bar).
Defaults.chat = [[
<style>
.composer { border: true; border-size: 1px; border-color: gray(0.45);
  background: gray(0); radius: 21px; pad: 6px; gap: 8px; }
.muted { color: gray(0.45); }
.center { text-align: center; }
.stream { flex: 10; }
.msg-input { flex: 3; }
.send { flex: 1; }
.bar { halign: between; gap: 8px; }
.bar .bar-cell { flex: 1; }
</style>
<div>
  <div class="stream" data-slot="chat:messages"></div>
  <row>
    <textarea class="msg-input" data-h="54px" data-bind="chat.draft"
      placeholder="Mensagem..." title="Mensagem"/>
    <button class="send" kind="primary" data-action="chat:send">Enviar</button>
  </row>
  <row class="bar">
    <button class="bar-cell" kind="ghost" icon="forward" data-action="chat:continue">Continuar</button>
    <button class="bar-cell" kind="ghost" icon="bars" data-action="chat:options">Opcoes</button>
  </row>
</div>
]]

return Defaults
