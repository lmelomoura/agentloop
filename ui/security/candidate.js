// ui/security/candidate.js
/* The candidate document (bin/security/candidate.py) as the screens draw it:
   a confidence chip wherever a finding is listed, and the full block --
   trace, intended control, conditions, the three scored fields -- wherever
   a finding is shown whole (analysis.js's secFindingRow). One module, so the
   two cannot drift from each other or from the report the same document
   renders into.

   textContent only, everywhere: every string here is the agent's prose about
   analysed code, and a repository must never be able to script this page. */
import { secEl } from "./dom.js";

// Most confident first -- the order the filter's picker lists them in.
export const SEC_CONFIDENCE = ["high", "medium", "low"];
const SCORED = [["confidence", "Confidence"], ["likelihood", "Likelihood"], ["impact", "Impact"]];

function _doc(f){
  const c = f && f.candidate;
  return c && typeof c === "object" ? c : null;
}

export function secConfidenceChip(f){
  // Self-contained on purpose: tests/test_page_contract.py lifts this one
  // function out of the bundle by name and runs it beside secFindRow, with
  // no `_doc` in scope.
  const c = f && f.candidate && typeof f.candidate === "object" ? f.candidate : null;
  const score = (f && f.confidence) || (c && c.confidence && c.confidence.score) || "";
  if(!score) return null;
  const chip = secEl("span", "secconf " + score, score);
  if(c && c.confidence && c.confidence.reason) chip.title = c.confidence.reason;
  return chip;
}

export function secCandidateBlock(f){
  const c = _doc(f);
  if(!c) return null;
  const box = secEl("div", "seccand");
  if(Array.isArray(c.trace) && c.trace.length){
    box.appendChild(secEl("div", "seccand-label", "Trace"));
    const ol = document.createElement("ol");
    c.trace.forEach(s => {
      const li = document.createElement("li");
      li.appendChild(secEl("span", "seccand-kind", s.kind || ""));
      li.appendChild(secEl("code", null, (s.file || "") + (s.line ? ":" + s.line : "")));
      li.appendChild(secEl("span", "seccand-scope", s.scope || ""));
      li.appendChild(secEl("span", null, s.description || ""));
      ol.appendChild(li);
    });
    box.appendChild(ol);
  }
  if(c.intended_control){
    box.appendChild(secEl("p", null, "Intended control: " + c.intended_control));
  }
  if(Array.isArray(c.conditions) && c.conditions.length){
    box.appendChild(secEl("div", "seccand-label", "Conditions"));
    const ul = document.createElement("ul");
    c.conditions.forEach(x => ul.appendChild(secEl("li", null, (x.kind || "") + ": " + (x.description || ""))));
    box.appendChild(ul);
  }
  const scored = SCORED.filter(([k]) => c[k] && typeof c[k] === "object")
    .map(([k, label]) => label + ": " + (c[k].score || "") + " — " + (c[k].reason || ""));
  if(scored.length) box.appendChild(secEl("p", "seccand-scored", scored.join(" · ")));
  return box;
}
