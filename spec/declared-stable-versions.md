# Declared Stable Versions

Every external version in uniterm stays at 0 until uniterm's maintainers declare it version 1. A version at 0
carries no compatibility promise. See UTERM-063 and ADR-13.

`scripts/check-external-versions.sh` runs in `make check` and in CI. It fails when an external version differs
from 0 and is not listed here. It reads these constants and nothing else:

- `ScriptProtocol.version`, ScriptWire's protocol version
- `ExecProtocol.version`, the exec wire's protocol version
- the version of each applet command schema, named by the applet type expression in its
  `AppletCommandSchema(` construction, such as `command schema MapViewerDescription.typeID`
- `UNITERM_JANET_API_VERSION`, the Janet scripting API's version, which `uniterm/api-version` reports
- `ControllerDescriptor.format`, the controller descriptor format

Internal versions are outside the check: DocumentWire, ImageWire, the layout file and each applet's saved state,
the map's command-pin snapshot, the browser's HSTS store, the policy file's format, and each permission kind's
edition.

## Who adds to the list

Only uniterm's maintainers add to this list, and an addition is the declaration. A session never adds to it to make
the check pass. Moving a version off 0 without a declaration is the mistake the check exists to catch.

## Format

Each entry is a bullet under the "Declared stable" heading below. The bullet starts with the constant's name in
backticks, exactly as the check prints it in its failure. The rest of the line is free text, such as the date and a
link to the declaration. Prose and bullets above the heading are never read as entries.

## Declared stable

None. Every external version is at 0.
