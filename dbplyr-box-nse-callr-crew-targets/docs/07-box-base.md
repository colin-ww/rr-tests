# `box::use(base[...])`: why it fails, and does it make sense?

Script: `07-box-base.R` writes `results/07-box-base.csv` (123 rows, about 55 s). Every import case runs in a **fresh R process** (callr), so nothing carries over from one case to the next.

## Short answer

- It is a **box bug, not an R 4.6 change**. It started in **box 1.1.3** (May 2023). box dev HEAD (= 1.2.3) still has it.
- Of everything tested, only `base` fails. All four forms fail the same way, at top level and inside a module:
  - `box::use(base)`
  - `box::use(base[nchar])`
  - `box::use(base[nch = nchar])`
  - `box::use(base[...])`
- These other base-R packages import fine in all four forms, at top level and in a module: `stats`, `utils`, `methods`, `tools`, `graphics`, `grDevices`. So do packages with lazy-loaded data: `datasets[mtcars]`, `dplyr[starwars]`, `stringr[fruit]`. That is 72 of 72 cases.
- Importing `base` is redundant but reasonable. `base::nchar` is fine in R, and so is `import builtins` in Python. A small fix in box makes it work (see below). An upstream issue is drafted but **not filed**.
- What you need today:
  - You never need to import base. Inside a module, base is already visible.
  - You **do** need to import `stats`, `utils`, `datasets` and the rest.

## Why it fails

- On every package import, box makes a list of the names you are allowed to import. That list is the package's exports plus its lazy-loaded datasets:

```r
# box 1.2.3, R/use.r (line 477 in the dev repo)
`mod_export_names.box$pkg_info` = function (info, mod_ns) {
    c(getNamespaceExports(mod_ns), ls(getNamespaceInfo(mod_ns, 'lazydata')))
}
```

- For base, `getNamespaceInfo()` stops with `operation not allowed on base namespace`. Base is special in R: it has no namespace metadata at all, so it has no "lazydata" entry either.
- `ls()` hides that real error. It has a fallback for when its first argument errors:
  - it turns the code into a string,
  - warns `'...' converted to character string`,
  - then looks for a search-list entry with that name.
- That is where the confusing message `no item called "getNamespaceInfo(mod_ns, "lazydata")" on the search list` comes from.
- The lazydata lookup arrived in box 1.1.3 (2023-05-02). Its NEWS entry is "Support lazy loading data from packages (#219)". In box 1.1.2 this function was just `getNamespaceExports(mod_ns)`, and `getNamespaceExports()` already handles base as a special case.
- How this was checked: real box 1.1.2 and 1.1.3 were installed into a scratch library and run on the **same R 4.6.1**.
  - With 1.1.2, `base[nchar]`, `base[nch = nchar]` and `base[...]` all work. There was no lazydata support yet, so `datasets[mtcars]` fails.
  - With 1.1.3, base fails with exactly today's error, and `datasets[mtcars]` works.
  - Old box versions are not usable on R 4.6 in general: `base$nchar` crashed R under 1.1.2, because of old C code. That crash is a separate issue.
- So the box version is what matters, not R.
  - The R NEWS files list no change to `getNamespaceInfo`, `asNamespace` or `ls`.
  - Older R versions were not run.
- No existing klmr/box issue reports this bug. Searches found only related, closed issues: #219, #294, #200, #181.

## Results (fresh process per case)

| package (name tested) | top level | inside a module |
|---|---|---|
| base (`nchar`) | **fails**, all 4 forms | **fails**, all 4 forms |
| stats, utils, methods, tools, graphics, grDevices | works | works |
| datasets (`mtcars`, lazydata) | works | works |
| dplyr (`starwars`), stringr (`fruit`), lazydata | works | works |
| base **with the fix below** | works | works |
| datasets / dplyr lazydata **with the fix** | still works | still works |

## Does `box::use(base)` make sense?

First, what a module can see with no imports at all (checked by the script):

- The lookup chain is:
  1. the module itself,
  2. its imports,
  3. box's `library`/`require`/`source` wrappers (they warn, then call the real function),
  4. `baseenv()`,
  5. nothing.
- So **base is always visible** in a module, and nothing else is: no other packages, no global variables. For example:
  - `nchar('abc')` works with no import.
  - `median()` fails: `could not find function "median"` (it is in stats).
  - `head()` fails the same way (it is in utils).
  - `mtcars` fails: `object 'mtcars' not found` (it is in datasets).
- `box::use(r/core[...])` ships with box. It brings in methods, stats, graphics, grDevices and utils. It does **not** include datasets.
- This matches the box FAQ: "Inside modules, only the 'base' package is attached."

So `box::use(base[nchar])` is redundant, but it is not wrong:

- In R, `base::nchar` is legal even though base is always attached.
- In Python, `import builtins` and `from builtins import len as ln` are legal and harmless (checked with python3).
- Once box is fixed, importing base has real uses:
  - **Aliasing**: `box::use(base[nch = nchar])`.
  - **Getting back a masked base function**. In a module, `box::use(dplyr[...])` makes `intersect` the `generics` version. `box::use(dplyr[...], base[intersect])` gives you base's version again (checked with the fix).
    - Order matters: the last import wins. Put `base[...]` **after** the wildcard. `box::use(base[intersect], dplyr[...])` still gives the generics version.
    - Today, write `base::intersect` instead.
  - **"Declare every dependency"** style, or a generated header that lists every package the same way.
- With the fix, `box::use(base[...])` at **top level** (in a script) has two harms. Inside a module neither one matters.
  - It puts 1407 copies of base objects on the search path, at position 2 (`mod:base`). The `.Last.value` copy is made once and then frozen: after `40 + 2`, `.Last.value` still showed `NULL`.
  - Because `mod:base` sits at position 2, it hides packages you attached earlier that replace base functions. After `library(dplyr)`, `intersect` comes from generics. After `box::use(base[...])`, it comes from base again.
  - So don't wildcard-import base in a script.

## What to do now

- Don't `box::use(base...)`. Call base functions directly; modules see them already.
- For an alias, use plain R: `nch <- base::nchar`. This works today, at top level and in a module.
- Inside modules, always import the other packages you use, for example `box::use(stats[median], utils[head])` or `box::use(r/core[...])`.
- `datasets` needs its own import: `box::use(datasets[mtcars])`.
- Upstream, the suggestion is to **allow it** rather than error:
  - It worked before 1.1.3.
  - It matches `base::` in R and `import builtins` in Python.
  - If the maintainers would rather forbid it, the error should at least say "base is always available inside modules; no need to import it".

## Suggested fix (box `R/use.r`, not filed)

```diff
 `mod_export_names.box$pkg_info` = function (info, mod_ns) {
-    c(getNamespaceExports(mod_ns), ls(getNamespaceInfo(mod_ns, 'lazydata')))
+    exports = getNamespaceExports(mod_ns)
+    # The base namespace has no namespace info, and hence no lazydata.
+    if (isBaseNamespace(mod_ns)) return(exports)
+    c(exports, ls(getNamespaceInfo(mod_ns, 'lazydata')))
 }
```

How it was checked, without touching the installed package (`assignInNamespace` in a scratch process):

- All 4 base forms work, at top level and in a module.
- datasets and dplyr lazydata still work (24 cases, all ok).
- box's own test suite from the dev repo gives the same result with and without the patch:
  - 167 tests, 551 expectations passed, 0 failures.
  - The one error is unrelated and happens without the patch too: `devtools` is not installed.

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md)
