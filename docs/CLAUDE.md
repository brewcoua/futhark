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
