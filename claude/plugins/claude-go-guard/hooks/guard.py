#!/usr/bin/env python3
"""claude-go guard: PreToolUse hook for Bash.

Commands that destroy data or rewrite shared history get permissionDecision
"ask": a person must approve them even where an allow rule, acceptEdits or
dontAsk would otherwise let them run. Interactive sessions show the reason in
the prompt; headless (-p) sessions refuse the command and tell the model why.

This catches the destructive commands a model emits by mistake. It is not a
security boundary: a determined model can obfuscate a command past any parser
(the sandbox is the boundary). Anything it cannot parse is sent to a person.

Usage: guard.py < hook-input.json    (or: guard.py --check '<command>' [cwd])
"""
import json, os, re, shlex, sys

SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish"}
WRAPPERS = {"sudo", "doas", "env", "nohup", "time", "nice", "ionice", "command", "builtin", "exec", "xargs", "timeout", "stdbuf"}
SEPARATORS = {";", "&&", "||", "|", "&", "|&", "(", ")", "{", "}", "!"}
DISK_TOOLS = {"mkfs", "wipefs", "shred", "fdisk", "sfdisk", "gdisk", "parted", "blkdiscard"}
GIT_GLOBAL_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}


class Unparseable(Exception):
    pass


def segments(command):
    """Split a shell command into simple commands (lists of words), with the
    separator that preceded each one."""
    lexer = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|(){}!")
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        tokens = list(lexer)
    except ValueError as e:  # unbalanced quotes
        raise Unparseable(str(e))
    segs, cur, before = [], [], None
    for t in tokens:
        if t in SEPARATORS or set(t) <= set(";&|(){}!"):
            if cur:
                segs.append((before, cur))
            cur, before = [], t
        else:
            cur.append(t)
    if cur:
        segs.append((before, cur))
    return segs


def strip_wrappers(words):
    """Drop leading sudo/env/nohup/... and VAR=value assignments."""
    i = 0
    while i < len(words):
        w = words[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
            i += 1
        elif os.path.basename(w) in WRAPPERS:
            i += 1
            # skip the wrapper's own options (and a timeout's duration)
            while i < len(words) and (words[i].startswith("-") or re.match(r"^\d+[smhd]?$", words[i])):
                i += 1
        else:
            break
    return words[i:]


class Ctx:
    def __init__(self, cwd):
        self.home = os.path.realpath(os.path.expanduser("~"))
        self.cwd = os.path.realpath(cwd)

    def resolve(self, path):
        """Real path of a command argument, or None if it uses shell expansion."""
        if "$" in path or "`" in path:
            return None
        p = os.path.expanduser(path)
        p = re.sub(r"(/\*|/\.\*|\*|\.\*)$", "", p) or "."  # rm -rf dir/* empties dir: judge dir
        return os.path.realpath(os.path.join(self.cwd, p))

    def inside(self, real):
        return real.startswith(self.cwd + os.sep)

    def judge_target(self, path, whole_cwd_ok=False):
        """Why removing/changing `path` recursively needs a person, or None."""
        real = self.resolve(path)
        if real is None:
            return f"{path!r} depends on shell expansion"
        if real == self.cwd:
            return None if whole_cwd_ok else f"{path!r} is the whole working directory"
        if real in ("/", self.home) or self.cwd.startswith(real + os.sep):
            return f"{path!r} contains the working directory"
        if not self.inside(real):
            return f"{path!r} is outside the working directory"
        return None


def short_flags(words):
    return "".join(w[1:] for w in words if re.match(r"^-[A-Za-z]+$", w))


def operands(words):
    out, opts_done = [], False
    for w in words:
        if w == "--" and not opts_done:
            opts_done = True
        elif opts_done or not w.startswith("-") or w == "-":
            out.append(w)
    return out


def check_rm(args, ctx):
    recursive = "r" in short_flags(args).lower() or "--recursive" in args
    if not recursive:
        return []
    if not operands(args):
        return ["rm -r whose targets are not on the command line (e.g. from xargs)"]
    return [f"rm -r of {why}" for why in filter(None, (ctx.judge_target(p) for p in operands(args)))]


def check_find(args, ctx):
    if "-delete" not in args and not any(a == "-exec" and i + 1 < len(args) and os.path.basename(args[i + 1]) == "rm"
                                         for i, a in enumerate(args)):
        return []
    roots = []
    for a in args:
        if a.startswith("-") or a in ("(", "!"):
            break
        roots.append(a)
    return [f"find -delete in {why}" for why in filter(None, (ctx.judge_target(p, True) for p in roots or ["."]))]


def check_recursive_perm(cmd, args, ctx):
    if "R" not in short_flags(args) and "--recursive" not in args:
        return []
    targets = operands(args)[1:]  # first operand is the mode / owner
    return [f"{cmd} -R on {why}" for why in filter(None, (ctx.judge_target(p, True) for p in targets))]


def check_git(args):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in GIT_GLOBAL_WITH_VALUE else 1
    if i >= len(args):
        return []
    sub, rest = args[i], args[i + 1:]
    flags = short_flags(rest)
    if sub == "push":
        if ("f" in flags or any(a.startswith(("--force", "--mirror", "--delete", "--prune")) for a in rest)
                or "d" in flags or any(a.startswith(("+", ":")) for a in operands(rest)[1:])):
            return ["git push that overwrites or deletes remote history"]
    elif sub == "reset" and "--hard" in rest:
        return ["git reset --hard discards uncommitted work"]
    elif sub == "clean" and ("f" in flags or "--force" in rest) and "n" not in flags and "--dry-run" not in rest:
        return ["git clean deletes untracked files"]
    elif sub == "checkout" and ("--" in rest or "." in rest or "f" in flags or "--force" in rest):
        return ["git checkout over paths discards uncommitted work"]
    elif sub == "restore" and not (("--staged" in rest or "S" in flags) and "--worktree" not in rest and "W" not in flags):
        return ["git restore discards uncommitted work"]
    elif sub == "stash" and rest[:1] in (["drop"], ["clear"]):
        return [f"git stash {rest[0]} deletes stashed work"]
    elif sub == "branch" and ("D" in flags or ("--delete" in rest and "--force" in rest)):
        return ["git branch -D deletes an unmerged branch"]
    elif sub in ("filter-branch", "filter-repo"):
        return [f"git {sub} rewrites history"]
    elif sub == "reflog" and rest[:1] in (["expire"], ["delete"]):
        return ["git reflog expire/delete removes recovery points"]
    elif sub == "update-ref" and "-d" in rest:
        return ["git update-ref -d deletes a ref"]
    return []


def check(command, cwd, depth=0):
    """Reasons the command needs a person's approval (empty if none)."""
    ctx = Ctx(cwd)
    try:
        segs = segments(command)
    except Unparseable as e:
        return [f"the command could not be parsed ({e})"]
    reasons = []
    if depth < 3:  # `...` substitutions run too, but shlex keeps them inside other words
        for inner in re.findall(r"`([^`]*)`", command):
            reasons += check(inner, cwd, depth + 1)
    for idx, (before, words) in enumerate(segs):
        words = strip_wrappers(words)
        if not words:
            continue
        cmd, args = os.path.basename(words[0].lstrip("`")), words[1:]
        c_flag = next((i for i, a in enumerate(args) if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a)), None)
        if cmd in SHELLS and c_flag is not None and depth < 3:
            reasons += check(args[c_flag + 1] if c_flag + 1 < len(args) else "", cwd, depth + 1)
        elif cmd in SHELLS and before == "|":
            if any(os.path.basename(strip_wrappers(w)[0]) in ("curl", "wget") for _, w in segs[:idx] if strip_wrappers(w)):
                reasons.append("piping a download into a shell runs unreviewed code")
        elif cmd == "rm":
            reasons += check_rm(args, ctx)
        elif cmd == "find":
            reasons += check_find(args, ctx)
        elif cmd in ("chmod", "chown", "chgrp"):
            reasons += check_recursive_perm(cmd, args, ctx)
        elif cmd == "git":
            reasons += check_git(args)
        elif cmd == "dd" and any(a.startswith("of=/dev/") for a in args):
            reasons.append("dd onto a device")
        elif cmd.split(".")[0] in DISK_TOOLS:
            reasons.append(f"{cmd} destroys disk contents")
    return reasons


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--check":
        print("\n".join(check(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else os.getcwd())) or "ok")
        return
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    command = (data.get("tool_input") or {}).get("command", "")
    reasons = check(command, data.get("cwd") or os.getcwd())
    if reasons:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": "claude-go guard: " + "; ".join(dict.fromkeys(reasons))
                                        + ". A person must approve this command.",
        }}))


if __name__ == "__main__":
    main()
