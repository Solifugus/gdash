// The page's own JavaScript, actually executed.
//
// gdash builds its client shim by string concatenation in gBASIC, and until
// GDASH-11 nothing ever parsed the result, let alone ran it: a typo would
// have reached every dashboard and broken every slicer, and the suite would
// have stayed green because the server was fine. That was tolerable while the
// shim only enhanced a page the server had already rendered. It is not
// tolerable now that the shim carries the refresh notification, which used to
// arrive over a connection the server held.
//
// Run under node because node is already on any machine that has a browser to
// test with, and because `vm` gives a context with nothing in it -- so the
// shim is proved to depend on nothing but the browser globals stubbed here.
//
// Usage:  node shim_check.js <baseline-v> <baseline-pub>  < shim.js
const vm = require('vm');
const fs = require('fs');

const shim = fs.readFileSync(0, 'utf8');
const baseV = process.argv[2];
const basePub = process.argv[3];

let pass = 0, fail = 0;
const ok = (name, got, want) => {
    if (got === want) { console.log('  ok   ' + name); pass++; }
    else { console.log(`  FAIL ${name}: expected <${want}> got <${got}>`); fail++; }
};

// One run of the shim: load it into a bare context, then fire the timer it
// registered with a canned answer from the version endpoint.
function poll(answer, fetchOk = true) {
    const state = { reloaded: false, url: null, interval: null, notice: { hidden: true } };
    const sandbox = {
        JSON, String, Promise, console,
        location: { pathname: '/d/sales', reload() { state.reloaded = true; } },
        document: {
            addEventListener() {},
            getElementById(id) { return id === 'gdash-notice' ? state.notice : null; },
            querySelector() { return null; },
            querySelectorAll() { return []; },
        },
        setInterval(fn, ms) { state.interval = { fn, ms }; return 1; },
        fetch(u) {
            state.url = u;
            return Promise.resolve({ ok: fetchOk, json: () => Promise.resolve(answer) });
        },
    };
    vm.createContext(sandbox);
    // A syntax error in the generated JavaScript throws HERE, which is the
    // cheapest assertion in this file and the one that has never existed.
    vm.runInContext(shim, sandbox);
    if (!state.interval) { throw new Error('the shim registered no poll timer'); }
    state.interval.fn();
    // Two turns: fetch resolves, then .json() resolves.
    return new Promise(r => setImmediate(() => setImmediate(() => r(state))));
}

(async () => {
    let st = await poll({ v: baseV, pub: basePub });
    ok('the shim parses and registers a poll', typeof st.interval.fn, 'function');
    ok('polling the version endpoint beside the page', st.url, '/d/sales/version');
    ok('on an interval of some seconds', st.interval.ms >= 1000 && st.interval.ms <= 30000, true);
    ok('an unchanged version does not reload', st.reloaded, false);
    ok('and reveals no notice', st.notice.hidden, true);

    // The baseline is embedded at render time. If it were learned on the first
    // poll instead, this case would be indistinguishable from the one above --
    // which is the bug that costs a viewer a refresh they were waiting for.
    st = await poll({ v: String(Number(baseV) + 1), pub: basePub });
    ok('a moved dataset version reloads the page', st.reloaded, true);

    // Design §7: a viewer pinned to a snapshot is offered the new version,
    // never yanked onto it.
    st = await poll({ v: baseV, pub: '9999.json' });
    ok('a moved publish pointer does NOT reload', st.reloaded, false);
    ok('it reveals the notice instead', st.notice.hidden, false);

    // A blip is not news. Reloading because one poll failed would turn a
    // momentary network fault into a lost slicer selection on every open tab
    // at once.
    st = await poll({ v: 'nonsense' }, false);
    ok('a failed poll changes nothing', st.reloaded, false);
    ok('and reveals no notice', st.notice.hidden, true);

    console.log(`shim: ${pass} passed, ${fail} failed`);
    process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.log('  FAIL the shim did not run: ' + e.message); process.exit(1); });
