# Voxa Docs

- [architecture.md](architecture.md): current single-process native Swift design, lifecycle, storage, build, and recovery.
- [native-migration-completion.md](native-migration-completion.md): stage 6 removal, user acceptance, and final validation.
- [swift-migration-plan.md](swift-migration-plan.md): agreed minimal native Swift architecture and migration plan, including parity, performance, upgrade, and rollback gates.
- [migration-baseline.md](migration-baseline.md): stage 1 source/rollback evidence, test results, measured values, and pending live checks.
- [native-recording-proof.md](native-recording-proof.md): stage 2 recorder, local development preview, fixture coverage, and hardware validation gate.
- [native-session-pipeline.md](native-session-pipeline.md): stage 3 session coordinator, transcription client, output worker, and regression evidence.
- [native-application-integration.md](native-application-integration.md): stage 4 native UI/hotkeys, settings/Keychain integration, and signed candidate validation.
- [native-candidate-validation.md](native-candidate-validation.md): stage 5 native package, upgrade/rollback checks, performance fixtures, meter fix, and user acceptance.
- [archive/](archive/README.md): historical daemon architecture, implementation plan, IPC protocol, and CLI usage.

Stage 1–4 reports preserve evidence as recorded at those checkpoints; later stages
supersede their implementation status. Retired baseline and recorder-preview
commands can be recovered from Git at `881b78f`.
