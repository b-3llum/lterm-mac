import Foundation

/// Help text printed by the CLI.
public enum Usage {
    public static let main = """
    lterm: control tool for lterm-mac

    usage:
      lterm                          open a new lterm window
      lterm -e CMD                   open a window that runs CMD
      lterm --attach user@host [-s NAME]
                                     ssh to host in a new tab, inside a tmux session you can reattach
      lterm md FILE [--split]        show a Markdown file in a new tab (or a split)
      lterm pane ...                 open, read, type into and wait for panes (lterm pane --help)
      lterm browse ...               a browser pane that scripts can drive (lterm browse --help)
      lterm integration install claude|codex
                                     make Claude Code or Codex report their state to lterm
      lterm integration uninstall claude|codex
      lterm integration              show what is installed
      lterm install [--dir DIR] [--force]
                                     link this tool into ~/.local/bin (or DIR)
      lterm keys                     list the keyboard shortcuts
      lterm --version

    Inside a pane, $LTERM_PANE_ID is that pane's id and "self" can be used as an id.
    """

    public static let pane = """
    usage:
      lterm pane split [--run CMD] [--down] [--pane ID] [--focus]
                                     split a pane (yours by default) and print the new pane's id
      lterm pane list [--json]       every pane: id, tab, size, focus, agent state, title
      lterm pane read ID [--lines N] the last N lines of text (default 50)
      lterm pane send ID TEXT [--no-enter]
                                     type TEXT and press Enter
      lterm pane keys ID KEY...      press keys: \(KeyNames.help)
      lterm pane wait ID --state done,blocked [--timeout S]
      lterm pane wait ID --idle S [--timeout S]
                                     wait for an agent state, or for S seconds without output
      lterm pane close ID
      lterm pane focus ID
      lterm pane state working|blocked|done|idle|none [--agent NAME] [--message TEXT] [--pane ID]
                                     report the state of the agent in this pane

    "pane wait" prints the state it saw and exits 1 on timeout.
    """

    public static let md = """
    usage: lterm md FILE [--split]
    Shows a Markdown file with its images in a new tab, or in a split next to your pane with --split.
    The view reloads when the file changes.
    """

    public static let browse = """
    usage:
      lterm browse open URL [--down] [--tab]   open a browser pane next to yours, print its id
      lterm browse go URL                      load another page
      lterm browse click SELECTOR | --text TEXT | --at X Y
      lterm browse type [--selector CSS] TEXT [--enter]
      lterm browse wait --text TEXT | --selector CSS [--timeout S]
      lterm browse text [body|CSS|links|html|title]
      lterm browse eval JAVASCRIPT             run JavaScript, print the result
      lterm browse shot [FILE.png]             save a screenshot (default screenshot.png)
      lterm browse back | forward | reload | url

    Every command works on the browser pane you opened last. Add --pane ID to pick another one.
    """

    public static let integration = """
    usage:
      lterm integration install claude   add hooks to ~/.claude/settings.json (a backup is kept)
      lterm integration install codex    add a notify command to ~/.codex/config.toml (a backup is kept)
      lterm integration uninstall claude|codex
      lterm integration [status]         show what is installed

    Restart the agent afterwards. The hooks run `lterm pane state ...` and do nothing outside lterm.
    """

    public static let keys = """
    Press Ctrl+Space, let go, then press a key:
      v / s      split right / down          t      new tab
      h j k l    move between panes          n / p  next / previous tab
      arrows     move between panes          1-9    go to tab
      H J K L    resize (tap again to repeat) w     close tab
      o          next pane                   c      copy mode
      z          zoom pane / restore         /      search scrollback
      x          close pane                  a      agents sidebar
      ?          help                        u      next agent that needs you
      d          detach (ssh sessions)

    Without the leader:
      Cmd+T new tab, Cmd+D / Cmd+Shift+D split right / down, Cmd+W close pane,
      Cmd+Shift+] / [ next / previous tab, Cmd+1-9 go to tab, Cmd+= / - / 0 font size,
      Cmd+C / Cmd+V copy / paste, Cmd+F search, Ctrl+Shift+A agents sidebar.

    Copy mode: h j k l, w b, 0 $, g G, ctrl-u / ctrl-d to move. v / V select, y copy,
      / search, n / N next / previous match, q quit.
    """
}
