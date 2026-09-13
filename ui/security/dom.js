/* The things every screen in this area builds with.

   secIcon is a thin pass to the page's own icon helper. The icon TABLE lives in
   dashboard.html, and so does the one line that injects its markup — see the
   comment on the rule in vocabulary.js. Keeping the name here means every call
   site reads exactly as it did inside the page.

   secIconHTML (Phase 4 Task 5) is the same table read a different way: the
   raw markup STRING for one entry, not an element wrapping it, for
   makePicker's own cfg.icon/row.icon (bin/dashboard.html's paintTrigger/
   paintList concatenate it into a trigger/row's own markup string, the same
   shape every other picker's cfg already passes). Reading the string back
   out of secIcon(name)'s own returned element would spell, bare, the one DOM
   property name this file's own sink guard (tests/test_page_contract.py)
   bans from every module under ui/ -- a READ is exactly as invisible to that
   guard's plain substring check as a write, and correctly so, since nothing
   there can tell code from prose. page.js's own comment on the bridge has
   the rest.

   secFill used to be a third thing here: it populated a bare <select> with
   .value/.textContent options, never markup, because a branch name is
   allowed to contain '<', '>' and '&' and a repository chooses it. Phase 4
   Task 5 converted its last three callers (sec-repo/sec-branch, both in
   analysis.js) to the house combo -- createCombo's own .set(value, options)
   takes an array of {v, label} instead, so this file no longer has a
   <select> left to feed. The text-not-markup rule it existed to keep still
   holds: every {v, label} this area builds now (see analysis.js and
   index-screen.js's own picker rows) is still .value/.textContent under
   createCombo/makePicker's own escaping, never a template string handed to
   the HTML parser. */
import { icon, iconHTML, sessionLost, TOKEN } from "./page.js";

export function secIcon(name){
  return icon(name);
}
export function secIconHTML(name){
  return iconHTML(name);
}
export function secEl(tag, cls, text){
  const n = document.createElement(tag);
  if(cls) n.className = cls;
  if(text != null) n.textContent = text;
  return n;
}

export async function secFetch(path){
  const r = await fetch(path, {headers:{"X-AL-Token":TOKEN}});
  // Same two codes /api/data treats as "go back to the login card", for the
  // same reason: a session that ended is a state, not an error to report.
  if(r.status === 401 || r.status === 428){ sessionLost(); throw new Error("signed out"); }
  const j = await r.json().catch(() => null);
  if(!r.ok) throw new Error((j && (j.error || j.output)) || ("HTTP " + r.status));
  return j;
}

/* ONE menu placement for every <details>/<summary>/.menu-pop in this area.
   Eight copies of the same ontoggle block used to live across five files,
   and all eight shared two defects the copies had faithfully reproduced:

   - the position was computed ONCE, on open, from getBoundingClientRect().
     Scroll any container afterwards and the trigger moves while the menu,
     being position:fixed, stays where it was -- the options float free of
     the button that opened them;
   - a left-aligned menu near the right edge was placed at the trigger's own
     left and ran off the viewport, clipped.

   position:fixed itself is right and stays: `.table-card{overflow:hidden}`
   clips an absolutely-positioned popup, which is why every copy used it.
   What changes is that the menu now closes on any scroll or resize while it
   is open (the way a native <select> does -- following the trigger frame by
   frame is unusual and never what the operator meant), and it is clamped to
   the viewport with an 8px margin on the right and the bottom, flipping
   above the trigger when there is more room there than below. */
export function secPlaceMenu(details, trigger, pop, align){
  const MARGIN = 8, GAP = 6;
  let onMove = null;
  const close = () => { if(details.open) details.open = false; };
  const detach = () => {
    if(!onMove) return;
    window.removeEventListener("scroll", onMove, true);
    window.removeEventListener("resize", onMove);
    onMove = null;
  };
  details.ontoggle = () => {
    pop.hidden = !details.open;
    if(!details.open){ detach(); return; }
    const r = trigger.getBoundingClientRect();
    pop.style.position = "fixed";
    pop.style.bottom = "auto";
    if(align === "right"){
      pop.style.left = "auto";
      pop.style.right = Math.max(MARGIN, window.innerWidth - r.right) + "px";
    }else{
      pop.style.right = "auto";
      pop.style.left = r.left + "px";
    }
    pop.style.top = (r.bottom + GAP) + "px";
    // Measured AFTER the first placement, because a hidden popup has no size
    // to clamp against until it is shown.
    const p = pop.getBoundingClientRect();
    if(align !== "right" && p.right > window.innerWidth - MARGIN){
      pop.style.left = Math.max(MARGIN, window.innerWidth - MARGIN - p.width) + "px";
    }
    if(p.bottom > window.innerHeight - MARGIN){
      const above = r.top - GAP - p.height;
      pop.style.top = (above >= MARGIN ? above
                       : Math.max(MARGIN, window.innerHeight - MARGIN - p.height)) + "px";
    }
    // `true`: capture, so a scroll inside ANY container reaches this, not
    // only the window's own. Registered on open and removed on close, never
    // left behind on a menu that was torn down open.
    onMove = close;
    window.addEventListener("scroll", onMove, true);
    window.addEventListener("resize", onMove);
  };
}
