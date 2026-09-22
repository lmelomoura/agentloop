# Upstream

These eleven guides are vendored byte for byte from
https://github.com/cloudflare/security-audit-skill
(`skills/security-audit/*.md`), at commit `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8` on 2026-09-22.

They are hunting material, not process: the audit skill's own SKILL.md,
HUNTING.md, RECONNAISSANCE.md and VALIDATION-AND-REPORTING.md describe a
workflow (hunters, verifiers, findings.json) that competes with
`skills/security-analysis/SKILL.md` and are deliberately NOT vendored.

## Rule

Never edit a guide in place. To update: fetch every file again at one new
commit, replace the set whole, and change the SHA and date above in the same
commit. `tests/security/test_guides.py` refuses a table that names a guide
this directory does not hold, and a SHA that is not 40 hex characters.

## Licence

MIT — copyright (c) Cloudflare, Inc. Full text below, as required.

```
MIT License

Copyright (c) 2025-2026 Cloudflare, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
