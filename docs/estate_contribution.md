# Contribution to `estate_design.md` §6

For the gbasic session. Written from gdash's side because CLAUDE.md forbids
editing that repo from here; copy what is useful into §5.

Ordered by what I would plant first if the estate could only hold a few.

---

## The structural point first, because it changes R3

**R3's truth record is binary and at least four of the traps below cannot be
scored against it.** "This pair is a relationship" and "this pair is not" do not
cover the case that matters most in real estates:

> `order_lines.customer_id` is denormalised from `orders.customer_id`. Every
> value is a real `customers.id`. The relationship is **real**, and the lineage
> **does not run that way** — it runs through `orders`.

A tool that reports `order_lines.customer_id → customers.id` is right about the
values and wrong about the lineage, and an ETL built on its answer computes
different totals the day the copy drifts. Scored as "true" it is rewarded for a
mistake; scored as "decoy" it is punished for noticing something real.

The truth record needs a *kind*, not a boolean. At minimum:

| kind | meaning |
|---|---|
| `enforced` | declared and the database checks it |
| `real_undeclared` | true, convention only (R4) |
| `real_indirect` | true, but the lineage runs through another table |
| `real_non_equality` | true, but not `a = b` (concatenation, substring, range) |
| `real_conditional` | true only for rows where a sibling column has a given value |
| `coincidence` | the decoy assertion R3 already has |

Without `real_indirect` and `real_conditional` the estate cannot pose its two
hardest questions, and both are ordinary in any warehouse.

---

## R13–R24

| | Planted | What it defeats |
| --- | --- | --- |
| R13 | **A denormalised copy** — `order_lines.customer_id`, written at order time, always a valid `customers.id` | **the assumption that a true inclusion is a true edge.** Every value-based method scores this as a strong FK; the lineage runs through `orders`. Needs `real_indirect` above to be scorable at all |
| R14 | **Sentinels in a real FK** — `-1` unknown, `0` not applicable, `999999` system, in an otherwise valid `customer_id` | **inclusion thresholds.** A tool requiring 100% containment rejects a real, declared-in-spirit relationship; one that tolerates 5% orphans accepts R7. The estate should make the sentinel rate cross whatever threshold is chosen |
| R15 | **A polymorphic association** — `attachments.owner_type` + `owner_id` pointing at four tables | **one column, one referent.** The mirror of R7: R7 references nothing while looking universal, this references several *conditionally*. Any candidate model keyed on a single column cannot express the answer, so it must either miss it or emit four false edges |
| R16 | **A composite key with a promiscuous member** — true key `(company_id, order_no)`, and `order_no` alone overlaps every company's orders | **single-column candidate generation**, which is what everyone builds first for the O(n²) reason. Finds a confident, wrong, single-column edge |
| R17 | **A type mismatch across a real relationship** — `varchar(10)` zero-padded `'00042'` on one side, `integer 42` on the other | **the type-compatibility prefilter.** Every implementation prunes candidates by type before comparing values, because the full cross-product is unaffordable — so this trap is load-bearing for performance and therefore rarely revisited once written |
| R18 | **Soft deletes** — parents carry `deleted_at`, children still reference them; the `active` view omits the parents | **profiling a view instead of a table**, and **orphan-rate-as-disproof.** Inclusion is 100% against the base table and broken against the interface everyone actually uses |
| R19 | **A relationship through a concatenation** — `gl_entry.reference = 'INV-' \|\| invoice.id`, and a fixed-width `cost_centre` whose first three characters are the branch code | **equality.** No value-overlap method finds either. Both are the normal shape of a general ledger, which is where "where did this number come from" gets asked most often |
| R20 | **A silent truncation in the pipeline** — source key `varchar(50)`, warehouse column `varchar(20)`; two distinct customers collapse into one | **high overlap as strong evidence.** The truncation makes the overlap *better* than reality. The fixture should include the two source rows that collapsed, so a tool can be asked the question that matters: not "is this an FK" but "is this key still unique" |
| R21 | **A "temporary" table that became load-bearing** — `staging.tmp_rebate_2019`, referenced by no constraint, read by a nightly job, breaks month-end if dropped | **degree-in-the-graph as importance.** R9 tests inventing lineage where there is none; this tests the opposite error — correctly finding nothing and therefore rating it removable. The truth record has to carry "no relationships **and** load-bearing", which is a fact no schema can supply |
| R22 | **A column that changed meaning at a date** — `status` numeric, one vocabulary before a 2021 migration and another after, disambiguated only by `created_at` | **treating a column as homogeneous.** Every profiler summarises a column as one distribution. A newcomer cannot guess it and neither can a tool; it is the purest "convention nobody wrote down" |
| R23 | **Two independent sequences that align** — `invoice.id` and `shipment.id` both start at 1, increment, and overlap almost perfectly for the first N rows | **value-overlap inference, at high cardinality.** R7 is universal and therefore suspicious; this looks like a clean, high-cardinality, near-perfect FK, which is the profile every heuristic trusts most |
| R24 | **Case, padding and collation** — `'ACME '` and `'ACME'` are the same company; `'ACME'` and `'acme'` are two different ones | **both directions at once.** Exact matching misses the first; normalised matching invents the second. There is no setting that gets both right, which is the point: the tool must report the ambiguity rather than resolve it |

---

## Two more, if there is room

| | Planted | What it defeats |
| --- | --- | --- |
| R25 | **An SCD2 dimension** — `dim_customer` has several rows per `customer_id` with `valid_from`/`valid_to`; facts join on `customer_sk`, and also carry a degenerate `customer_id` | **one row per key.** Value overlap on `customer_id` reports a many-to-many between fact and dimension, which is arithmetically true and analytically wrong. The real edge is on the surrogate |
| R26 | **The same entity split by date** — `orders` and `orders_archive`, partitioned, so their ids are **disjoint by construction** | **overlap-based unification.** These are one entity with zero value overlap: the evidence points exactly the wrong way, and the only signal is structural (identical column sets) |

---

## What made schemas hard, the first time

Three things, none of which is a relationship:

- **A column present in eighty tables that is null in seventy-nine.** It was
  added by a framework migration. Its presence means nothing and it dominates
  every "common column" report.
- **Table names that encode a history nobody remembers** — `customer`,
  `customer2`, `customer_new`, `customer_v2_final`. The live one is `customer2`.
  Nothing in the schema says so; the only evidence is which one the application
  writes to, which is not in the database at all.
- **A schema whose only accurate documentation is a view.** The tables are a
  mess; the view is the contract, and the business meaning of a column exists
  only in the expression that produces it. This extends R11 with a purpose: not
  "can the tool follow a view" but "does it know the view is the interface".

---

## A coverage argument, worth more than another example

Several traps here defeat the **same** mitigation, and that is the useful
structure rather than a redundancy:

| mitigation an implementation will reach for | defeated by |
|---|---|
| read declared constraints | R4, R10 |
| name similarity | R6, R8 |
| type prefilter | R17 |
| value inclusion / overlap | R7, R13, R23, R26 |
| inclusion threshold tuning | R14, R18 |
| single-column candidates | R15, R16 |
| equality itself | R19, R24 |
| graph degree as importance | R9, R21 |
| column-level profiling | R22, and the eighty-table null column |

**A trap that defeats no mitigation is decoration** — the design already says
this. The inverse is the sharper test: *a mitigation defeated by no trap is an
untested assumption*, and the estate should be read that way before it is
built. On this list the thinnest column is the type prefilter, defeated only by
R17 — which is the one everybody writes and nobody revisits.
