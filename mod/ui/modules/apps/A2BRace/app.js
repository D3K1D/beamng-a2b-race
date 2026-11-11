// A2B Race HUD app.
// A small bar on the HUD; the party window and the big countdown / result text float on the
// page (appended to <body>) so the HUD slot never clips them. Everything the app shows comes
// from 'A2BRaceState' (game Lua, 10 times a second); buttons call a2brace_main.*.
(function () {
  var PANEL = `
<div class="a2b-panel" ng-show="ui.panel">
  <div class="a2b-head"><b>A2B Race</b><span class="a2b-dim"> {{s.version}} &middot; {{s.mode === 'mp' ? 'multiplayer' : 'solo (single-player)'}}</span>
    <button class="a2b-close" ng-click="ui.panel = false" title="Close">&#10005;</button></div>

  <div class="a2b-warn" ng-if="s.noServer">This server doesn't run A2B Race. Ask the owner to install the A2B Race server pack.</div>
  <div class="a2b-dim" ng-if="!s.ready && !s.noServer">Connecting&hellip;</div>

  <div ng-if="s.ready">
    <div ng-repeat="inv in s.view.invites" class="a2b-invite">
      <b>{{inv.host}}</b> invited you to race
      <div class="a2b-row"><button class="a2b-btn go" ng-click="call('accept', inv.party)">Accept</button>
        <button class="a2b-btn" ng-click="call('decline', inv.party)">Decline</button></div>
    </div>

    <div ng-if="!s.view.party">
      <p class="a2b-dim">You're not in a race party.</p>
      <button class="a2b-btn go wide" ng-click="call('host')">Host a race</button>
    </div>

    <div ng-if="s.view.party">
      <div class="a2b-sec">Party<span ng-if="isHost()"> (you're the host)</span></div>
      <div ng-repeat="m in s.view.party.members" class="a2b-member">
        <span ng-if="m.host" title="Host">&#9733;</span> {{m.pid === s.view.me ? m.name + ' (you)' : m.name}}
      </div>
      <div class="a2b-hint" ng-if="!isHost()">{{hostName()}} sets the points and starts the race. You stay in this party for the next race too.</div>

      <div ng-if="isHost()">
        <div class="a2b-sec">Points</div>
        <div class="a2b-row"><span class="a2b-pt a">A</span><span class="a2b-lbl">{{s.view.party.a ? 'Start set' : 'Not set'}}</span>
          <button class="a2b-btn" ng-click="setPoint('A', 'car')" title="Where you are now, facing your way">My spot</button>
          <button class="a2b-btn" ng-click="setPoint('A', 'map')" title="The spot you clicked on the big map (M)">Map pin</button></div>
        <div class="a2b-row"><span class="a2b-pt b">B</span><span class="a2b-lbl">{{s.view.party.b ? 'Finish set' : 'Not set'}}</span>
          <button class="a2b-btn" ng-click="setPoint('B', 'car')" title="Where you are now">My spot</button>
          <button class="a2b-btn" ng-click="setPoint('B', 'map')" title="The spot you clicked on the big map (M)">Map pin</button></div>
        <div class="a2b-hint">Map pin: open the big map (M), click a spot so a route appears, come back here and press <i>Map pin</i>. {{s.mapPin ? 'A map pin is set now.' : ''}}
          A picked from the map faces towards B; <i>My spot</i> faces the way you're facing.</div>

        <div ng-if="s.mode === 'mp'">
          <div class="a2b-sec">Invite players</div>
          <div class="a2b-dim" ng-if="!invitable().length">Nobody else to invite right now.</div>
          <div ng-repeat="p in invitable()" class="a2b-row">
            <span class="a2b-lbl">{{p.name}}<span class="a2b-dim" ng-if="p.party"> (in a party)</span></span>
            <button class="a2b-btn" ng-click="call('invite', p.pid)" ng-disabled="invited(p.pid)">{{invited(p.pid) ? 'Invited' : 'Invite'}}</button>
          </div>
        </div>

        <div class="a2b-sec">Race</div>
        <button class="a2b-btn go wide" ng-if="!raceOn()" ng-click="call('start')" ng-disabled="!s.view.party.a || !s.view.party.b">START RACE</button>
        <button class="a2b-btn bad wide" ng-if="raceOn()" ng-click="call('cancel')">Stop race</button>
        <div class="a2b-hint">Start: everyone in the party is teleported and repaired at A, held for a 10 second countdown, then GO. First to B wins; everyone else blows up. Reset, repair or teleport during the race = back to A.</div>
      </div>

      <div class="a2b-row" style="margin-top:12px"><button class="a2b-btn" ng-click="call('leave')">Leave party</button></div>
    </div>
    <div class="a2b-warn" ng-if="!s.hasCar">Get in a car: walking players race in the last car they drove.</div>
  </div>
</div>`

  var OVERLAY = `
<div class="a2b-overlay">
  <div class="a2b-count" ng-if="s.race && s.race.phase === 'grid' && s.race.count > 0 && !s.banner">{{s.race.count}}</div>
  <div class="a2b-banner" ng-if="s.banner" ng-class="s.banner.kind">{{s.banner.text}}</div>
</div>`

  var STYLE = `
.a2b-bar { display:flex; align-items:center; gap:8px; height:36px; padding:0 10px; border-radius:18px; background:rgba(18,18,22,0.88); box-sizing:border-box; font:12px/1.3 sans-serif; color:#eee; cursor:pointer; user-select:none }
.a2b-bar:hover { background:rgba(40,40,48,0.92) }
.a2b-flag { font-size:15px }
.a2b-status { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
.a2b-badge { background:#ff3b3b; color:#fff; border-radius:9px; padding:0 6px; font-weight:700 }
.a2b-panel { position:fixed; top:90px; left:260px; width:330px; max-height:calc(100vh - 140px); overflow:auto; z-index:10000; padding:12px 14px; border-radius:12px;
  background:rgba(18,18,22,0.95); box-shadow:0 8px 30px rgba(0,0,0,0.5); font:12.5px/1.45 sans-serif; color:#eee; box-sizing:border-box }
.a2b-head { display:flex; align-items:center; gap:6px; margin-bottom:8px; font-size:14px }
.a2b-close { margin-left:auto; border:0; background:transparent; color:#ccc; font-size:15px; cursor:pointer }
.a2b-sec { margin:12px 0 4px; font-size:11px; text-transform:uppercase; letter-spacing:1px; opacity:0.6 }
.a2b-row { display:flex; align-items:center; gap:6px; margin:5px 0 }
.a2b-lbl { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
.a2b-btn { border:0; border-radius:6px; padding:4px 10px; cursor:pointer; background:rgba(255,255,255,0.14); color:#fff; font:inherit }
.a2b-btn:hover:not([disabled]) { background:rgba(255,255,255,0.26) }
.a2b-btn[disabled] { opacity:0.45; cursor:default }
.a2b-btn.go { background:#1fae4b } .a2b-btn.go:hover:not([disabled]) { background:#27c95a }
.a2b-btn.bad { background:#c62828 }
.a2b-btn.wide { width:100%; padding:8px; font-weight:700; letter-spacing:0.5px }
.a2b-pt { width:20px; height:20px; border-radius:10px; text-align:center; line-height:20px; font-weight:800; flex:none }
.a2b-pt.a { background:#1fae4b } .a2b-pt.b { background:#e53935 }
.a2b-member { padding:2px 0 }
.a2b-invite { background:rgba(31,174,75,0.18); border:1px solid #1fae4b; border-radius:8px; padding:8px; margin-bottom:8px }
.a2b-hint { font-size:11px; opacity:0.6; margin:4px 0 }
.a2b-dim { opacity:0.65 }
.a2b-warn { color:#ffb36b; margin:6px 0 }
.a2b-overlay { position:fixed; left:0; right:0; top:22vh; text-align:center; pointer-events:none; z-index:9999; font-family:sans-serif }
.a2b-count, .a2b-banner { display:inline-block; color:#fff; font-weight:900; text-shadow:0 4px 18px rgba(0,0,0,0.8), 0 0 2px #000 }
.a2b-count { font-size:140px; line-height:1 }
.a2b-banner { font-size:72px; letter-spacing:2px }
.a2b-banner.go { color:#3dff6e; font-size:120px }
.a2b-banner.win { color:#ffd84a; animation:a2b-pulse 0.5s ease-in-out infinite alternate }
.a2b-banner.bad { color:#ff5a3d }
.a2b-banner.lose { color:#ddd }
@keyframes a2b-pulse { from { transform:scale(1) } to { transform:scale(1.12) } }`

  angular.module('beamng.apps')
  .directive('a2bRace', ['$rootScope', '$compile', function ($rootScope, $compile) {
    return {
      template: `
<div style="width:100%;height:100%">
  <div class="a2b-bar" ng-click="ui.panel = !ui.panel" title="A2B Race">
    <span class="a2b-flag">&#127937;</span>
    <span class="a2b-status">{{status()}}</span>
    <span class="a2b-badge" ng-if="s.view.invites.length">{{s.view.invites.length}}</span>
  </div>
</div>`,
      replace: true,
      restrict: 'EA',
      scope: true,
      link: function (scope) {
        scope.s = { view: {} }
        scope.ui = { panel: false }

        if (!document.getElementById('a2brace-style')) {
          var st = document.createElement('style'); st.id = 'a2brace-style'; st.textContent = STYLE; document.head.appendChild(st)
        }
        var panel = $compile(PANEL)(scope)
        var overlay = $compile(OVERLAY)(scope)
        document.body.appendChild(panel[0])
        document.body.appendChild(overlay[0])

        function lua(fn, arg) {
          var a = arg === undefined ? '' : JSON.stringify(arg)
          bngApi.engineLua('a2brace_main.' + fn + '(' + a + ')')
        }
        scope.call = lua
        scope.setPoint = function (which, source) { bngApi.engineLua('a2brace_main.setPoint("' + which + '","' + source + '")') }

        function party() { return scope.s.view && scope.s.view.party }
        scope.isHost = function () { var p = party(); return !!p && p.host === scope.s.view.me }
        scope.hostName = function () {
          var p = party(); if (!p) return ''
          for (var i = 0; i < p.members.length; i++) if (p.members[i].host) return p.members[i].name
          return 'The host'
        }
        scope.raceOn = function () { var p = party(); return !!p && p.phase !== 'idle' && p.phase !== 'done' }
        scope.invitable = function () {
          var p = party(), list = (scope.s.view && scope.s.view.players) || []
          return list.filter(function (x) { return !p || x.party !== p.id })
        }
        scope.invited = function (pid) { var p = party(); return !!p && (p.invited || []).indexOf(pid) >= 0 }
        scope.status = function () {
          var s = scope.s
          if (s.noServer) return 'Not on this server'
          if (!s.ready) return 'A2B Race'
          if (s.race && s.race.phase === 'grid') return 'Get ready... ' + (s.race.count || '')
          if (s.race && s.race.phase === 'racing') return 'RACE! Get to B'
          var p = party()
          if (!p) return (s.view.invites && s.view.invites.length) ? 'Race invite!' : 'Host a race'
          if (p.phase === 'boom') return 'Race over'
          return 'Party of ' + p.members.length + (scope.isHost() ? ' (host)' : '')
        }

        var off = $rootScope.$on('A2BRaceState', function (e, s) {
          if (!s.view) s.view = {}
          if (!Array.isArray(s.view.invites)) s.view.invites = s.view.invites ? Object.values(s.view.invites) : []
          if (!Array.isArray(s.view.players)) s.view.players = s.view.players ? Object.values(s.view.players) : []
          if (s.view.party) {
            if (!Array.isArray(s.view.party.members)) s.view.party.members = Object.values(s.view.party.members || {})
            if (!Array.isArray(s.view.party.invited)) s.view.party.invited = Object.values(s.view.party.invited || {})
          }
          scope.$evalAsync(function () { scope.s = s })
        })

        scope.$on('$destroy', function () {
          off()
          panel.remove()
          overlay.remove()
        })
      }
    }
  }])
})()
