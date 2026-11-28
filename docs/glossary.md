# Glossary

Terms used across uniterm's docs and specs. Each entry links to the proposal or ADR that defines it.

## Layout

- **Window.** A macOS window. It holds one pane tree, a status bar, and a command palette.
- **Pane.** A leaf of a window's pane tree. Each pane runs one applet. Splits divide a window into panes.
- **Group.** A pane-tree node that a program creates for the panes it opens or lays out. It records its owner and never
  merges into its parent. See UTERM-004, "Group node kind".
- **Applet.** The kind of thing a pane runs, such as the terminal, browser, data viewer, or REPL.
- **Tab.** One of several views inside an applet that supports tabs. The terminal and the browser have tabs.
- **Place.** Anything a program can make and address: a pane, a tab, or a later kind of thing. See ADR-16.

## Programs

- **Program.** The umbrella term for a script, a controller, or an exec driver. A program acts for the user, and its
  operation behaves as the user's would. See ADR-15. In some older text, "program" instead means a process running in a
  terminal pane, as in "program mode". Context tells the two apart.
- **Script.** A Janet file run with `uniterm run`, or code typed into a REPL. It reaches the app over ScriptWire. See
  UTERM-003.
- **Controller.** A packaged program with a `controller.json` descriptor. The descriptor lists its entry, the digests
  of its files, and the permissions it declares. Its entry is a Janet script or a native binary. The user can trust a
  controller by version or by signing identity. See UTERM-004, "Controller trust and approval choices".
- **Exec driver.** A program attached to one pane to drive its applet. It reads applet events on stdin and writes
  commands on stdout. It can be written in any language. See UTERM-004, "Control modes and exec drivers", and UTERM-028.
- **Source pane.** The pane a program acts for. For a script run from a terminal, it is that terminal's pane.

## Control

- **Remote-controlled.** A pane's access mode that lets programs address it, within the trust rules. The pane shows a
  marker. See UTERM-004.
- **Disconnected.** A pane's access mode that refuses programs. An attached exec driver keeps working. See UTERM-004.
- **Power.** A permission a controller declares, such as `pane-control`, `clipboard-read`, or `host-launch`.

## Wires and versions

- **ScriptWire.** The versioned protocol between the app and scripts or native controllers. It runs over the app's
  local listener. See UTERM-003 and UTERM-056.
- **Exec wire.** The versioned protocol between the app and an exec driver. It is JSON lines over the driver's stdin
  and stdout. See UTERM-004, "Exec wire format".
- **External wire.** A wire to a program deployed apart from uniterm, ScriptWire and the exec wire. Its version is an
  external version. At version 0 it makes no compatibility promise. From version 1 it stays compatible across versions,
  per ADR-13.
- **Internal wire.** A wire whose two ends ship in the uniterm bundle, DocumentWire and ImageWire. Its version is an
  internal version, and it refuses any version but its own.
- **External version.** A version that a program or file uniterm does not build names or checks. These are
  ScriptWire's, the exec wire's, each applet command schema's, `uniterm/api-version`, the controller descriptor
  format. It stays at 0 until uniterm's maintainers declare it version 1, per UTERM-063.
- **Internal version.** A version only uniterm reads, such as an internal wire's, the layout file's, and a permission
  kind's edition. It keeps its own rules.
- **Declared stable.** An external version uniterm's maintainers have declared version 1. Its compatibility promise
  holds from then on.
