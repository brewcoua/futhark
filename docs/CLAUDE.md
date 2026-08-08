# Documentation instructions

These instructions apply to all files under `docs/`. This repository is public.

The implementation, configuration, tests, and existing documentation are the authority on what is currently true. This file is the authority on how to communicate it.

## Before you write

- Read the relevant documentation, implementation, configuration, and tests first.
- Prefer editing the page that already owns a topic over creating a new one. Keep each fact in one authoritative location and link to it instead of restating it.
- When existing documentation contradicts the implementation, treat the implementation as correct, fix the documentation, and state what changed. If the intended behavior is genuinely ambiguous, ask instead of guessing.

## Reader and purpose

- Identify the reader and their goal before writing.
- Assume the reader is competent but does not know undocumented repository context.
- Organize the document around the reader's task, not the system's internal structure.
- Do not add detail that fails to help the reader understand, decide, execute, or verify something.

A reader unfamiliar with the author's context should be able to complete the documented task without asking a follow-up question.

## Structure

- Start with a concise purpose and expected outcome.
- List prerequisites, assumptions, required permissions, supported versions, environment details, and dependencies.
- Give a minimal quick-start path before deeper explanation.
- Use numbered steps for procedures and headings for navigation.
- Add a verification step after each important action, and state the observable condition that indicates success.
- Explain why a non-obvious step is necessary.
- Include rollback, cleanup, or recovery instructions when an operation can change or damage state.
- Document common failures with their symptoms, causes, and recovery steps.
- Put conceptual background and reference material after the practical path.
- Keep orientation shallow and detail deep. Top-level pages say what something is and point to specific documentation.
- Add a section only when it contains something real and verifiable. Never add a section or header for symmetry, including generic "Overview," "Conclusion," and "Additional Resources."

## Diagrams

Diagrams are ```d2 fences rendered inline by `mdbook-d2`. `docs/theme/d2.css` remaps d2's theme slots to the mdbook theme variables so a diagram follows the reader's selected theme.

- Use d2's default colors for the subject of the diagram. They carry the slot classes that `docs/theme/d2.css` repaints. Express meaning with `stroke-width`, `stroke-dash`, and arrowhead shape before reaching for color.
- Declare every style once in a `classes:` block at the top of the fence and attach it with `class:`. Do not repeat a `style` block per node or edge, and do not write a color at the point of use.
- Explicit color comes from this palette. The stylesheet matches on the color name, so the name is the contract:

  | Class name  | stroke / fill               | Means                                                           |
  | ----------- | --------------------------- | --------------------------------------------------------------- |
  | `muted`     | `dimgray`                   | Annotation, or an edge deliberately drawn back from the subject |
  | `denied`    | `firebrick`                 | Denied, blocked, or danger                                      |
  | `boundary`  | `seagreen` / `honeydew`     | Roots and sinks, or the start and end of a sequence             |
  | `secondary` | `mediumpurple` / `lavender` | A second kind of node, distinct but not de-emphasized           |
  | `external`  | `goldenrod` / `cornsilk`    | A third party or resource outside this repository's control     |

- An edge's stroke color also fills its arrowhead, so an edge may only take a color from the palette. Anything else leaves the arrowhead at the literal color while the line follows the theme.
- Adding a color outside the palette requires a matching `[stroke=…]` and `[fill=…]` pair in `docs/theme/d2.css`. Without them it stays fixed across all five themes.
- State what the colors and line styles mean in the prose immediately above the fence. Do not draw a legend inside the diagram.
- ELK, set per-file with `vars: { d2-config: { layout-engine: elk } }`, routes orthogonally instead of curving. It helps a diagram whose edges are too dense to follow, which is why `docs/src/conventions/ordering.md` uses it; the rest use the default dagre. It does not fix overlapping labels. Those come from label length against converging edges, so shorten the label or move the detail into the prose.

## Accuracy and uncertainty

- Do not invent behavior, commands, defaults, outputs, compatibility information, file paths, or supported versions.
- Verify every factual claim against the implementation, configuration, tests, or a reliable existing source.
- Distinguish confirmed behavior from inference, recommendation, and open question.
- Mark anything unverified as unverified, or leave it out. Never present it as fact.
- State assumptions explicitly when a procedure depends on them.
- Prefer a smaller accurate document over a comprehensive document containing guesses.

## Commands, examples, and values

- Show the actual command, path, input, and expected output instead of describing them abstractly. Write `just --list`, not "list the available recipes."
- Make commands safe to copy and run, and idempotent where possible.
- Mark placeholders clearly and explain what values belong there.
- Warn before destructive, irreversible, privileged, or production-affecting operations.
- Never include secrets, credentials, tokens, private keys, or identifying values, including real addresses, private endpoints, account identifiers, and key identifiers. Refer to where the value is stored instead of publishing it.
- Tag code fences with their language.
- Keep examples representative of the real system and copyable where appropriate.

## Voice and style

- Use second person and imperative mood: "Add the new entry," not "A new entry would need to be added."
- Use short, direct sentences and active voice. Vary sentence length and structure.
- Cut throat-clearing such as "In today's cloud-native landscape" and "It's important to note that."
- Use plain verbs. Use "use" instead of "leverage" or "utilize."
- Cut inflated adjectives such as "robust," "seamless," and "streamlined" unless they describe a specific, verifiable property.
- Do not summarize a section immediately after explaining it.
- Do not use em dashes, emoji as bullet icons, or decorative horizontal rules.
- Reuse the existing name for a component or concept. Do not introduce synonyms.

## After changes

A change can make documentation wrong by omission. Search for every page affected by:

- Renamed, moved, added, or removed files and commands.
- Procedures that gained, lost, or reordered steps.
- Changed defaults, interfaces, configuration, permissions, or dependencies.
- Examples, screenshots, links, or outputs that no longer exist.
- Changed failure modes, recovery steps, or compatibility requirements.

Then, before finishing:

- Run every documented procedure in a clean or representative environment, and verify commands, paths, links, configuration, and outputs.
- If a procedure cannot be run, do not claim it works. Mark it unverified and report exactly what was not tested and why.
- Confirm that prerequisites and version requirements are complete.
- Confirm that destructive operations carry warnings and recovery guidance.
- Run the repository's configured documentation and validation checks on the files you touched.
