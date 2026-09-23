# python3 test/state-file-test.py
# Runs bin/state-file against throwaway directories, planting the links and
# loose permissions it has to refuse. A breadcrumb owned by another user needs
# root to set up and is not covered here.
import os
import stat
import subprocess
import sys
import tempfile
import time

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "state-file")
passed = 0


def check(name, fn):
    global passed
    with tempfile.TemporaryDirectory() as base:
        fn(os.path.realpath(base))
    passed += 1
    print("  ok  " + name)


def run(action, directory, payload=None):
    done = subprocess.run([sys.executable, HELPER, action, directory],
                          input=payload if payload is not None else b"",
                          capture_output=True, timeout=10)
    return done.returncode, done.stdout, done.stderr.decode()


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def names(directory):
    return sorted(os.listdir(directory))


def victim(base):
    path = os.path.join(base, "victim")
    with open(path, "wb") as f:
        f.write(b"keep me\n")
    return path


def unchanged(path):
    with open(path, "rb") as f:
        return f.read() == b"keep me\n"


def fresh_read_makes_the_directory(base):
    state = os.path.join(base, "state", "stay-awake-sessions")
    code, out, _ = run("read", state)
    assert code == 3 and out == b"", (code, out)
    assert mode(state) == 0o700, oct(mode(state))


def a_write_reads_back_as_written(base):
    state = os.path.join(base, "stay-awake-sessions")
    payload = '{"label":"a \\"quoted\\" $(label) ☀","sessions":[]}\nline two\n'.encode()
    assert run("write", state, payload)[0] == 0
    code, out, _ = run("read", state)
    assert code == 0 and out == payload, (code, out)
    hold = os.path.join(state, "hold")
    assert stat.S_ISREG(os.lstat(hold).st_mode) and mode(hold) == 0o600, oct(mode(hold))
    assert names(state) == ["hold"], names(state)


def a_link_at_hold_is_replaced_not_followed(base):
    state = os.path.join(base, "stay-awake-sessions")
    os.mkdir(state, 0o700)
    target = victim(base)
    os.symlink(target, os.path.join(state, "hold"))
    code, out, err = run("read", state)
    assert code == 5 and out == b"" and "link" in err, (code, out, err)
    assert run("write", state, b'{"sessions":[]}\n')[0] == 0
    assert unchanged(target)
    assert stat.S_ISREG(os.lstat(os.path.join(state, "hold")).st_mode)


def a_link_at_the_old_staging_name_is_left_alone(base):
    state = os.path.join(base, "stay-awake-sessions")
    os.mkdir(state, 0o700)
    target = victim(base)
    os.symlink(target, os.path.join(state, "hold.tmp"))
    assert run("write", state, b'{"sessions":[]}\n')[0] == 0
    assert unchanged(target)
    assert os.path.islink(os.path.join(state, "hold.tmp"))


def a_linked_directory_is_refused(base):
    elsewhere = os.path.join(base, "elsewhere")
    os.mkdir(elsewhere, 0o700)
    state = os.path.join(base, "stay-awake-sessions")
    os.symlink(elsewhere, state)
    assert run("read", state)[0] == 4
    assert run("write", state, b'{"sessions":[]}\n')[0] == 4
    assert names(elsewhere) == [], names(elsewhere)
    dangling = os.path.join(base, "dangling")
    os.symlink(os.path.join(base, "nowhere"), dangling)
    assert run("write", dangling, b'{"sessions":[]}\n')[0] == 4
    assert not os.path.exists(os.path.join(base, "nowhere"))


def a_loose_directory_of_ours_is_closed(base):
    state = os.path.join(base, "stay-awake-sessions")
    os.mkdir(state)
    os.chmod(state, 0o777)
    assert run("write", state, b'{"sessions":[]}\n')[0] == 0
    assert mode(state) == 0o700, oct(mode(state))


def a_shared_directory_above_is_refused(base):
    for bits in (0o777, 0o775):
        shared = os.path.join(base, "shared-%o" % bits)
        os.mkdir(shared)
        os.chmod(shared, bits)
        state = os.path.join(shared, "stay-awake-sessions")
        code, _, err = run("write", state, b'{"sessions":[]}\n')
        assert code == 4 and "written by others" in err, (bits, code, err)
        assert not os.path.exists(os.path.join(state, "hold"))


def a_sticky_directory_above_is_fine(base):
    sticky = os.path.join(base, "sticky")
    os.mkdir(sticky)
    os.chmod(sticky, 0o1777)
    state = os.path.join(sticky, "stay-awake-sessions")
    assert run("write", state, b'{"sessions":[]}\n')[0] == 0


def a_breadcrumb_that_is_not_plainly_ours_is_ignored(base):
    state = os.path.join(base, "stay-awake-sessions")
    assert run("write", state, b'{"sessions":[]}\n')[0] == 0
    hold = os.path.join(state, "hold")
    os.link(hold, os.path.join(base, "second-name"))
    assert run("read", state)[0] == 5
    os.unlink(os.path.join(base, "second-name"))
    os.chmod(hold, 0o620)
    assert run("read", state)[0] == 5
    os.chmod(hold, 0o644)
    assert run("read", state)[0] == 0, "readable by others is not writable by others"


def odd_things_at_hold_are_ignored(base):
    state = os.path.join(base, "stay-awake-sessions")
    os.mkdir(state, 0o700)
    hold = os.path.join(state, "hold")
    os.mkfifo(hold, 0o600)
    started = time.monotonic()
    assert run("read", state)[0] == 5
    assert time.monotonic() - started < 5, "a pipe must not hang the read"
    os.unlink(hold)
    with open(hold, "wb") as f:
        f.write(b"x" * ((1 << 20) + 1))
    assert run("read", state)[0] == 5
    os.unlink(hold)
    os.mkdir(hold)
    assert run("read", state)[0] == 5
    code, _, _ = run("write", state, b'{"sessions":[]}\n')
    assert code == 1, code
    assert names(state) == ["hold"], "a failed write leaves no staging file"


def nothing_is_written_from_nothing(base):
    state = os.path.join(base, "stay-awake-sessions")
    assert run("write", state, b"")[0] == 1
    assert run("write", state, b"\n  \n")[0] == 1
    assert not os.path.exists(os.path.join(state, "hold"))
    assert run("read", "relative/path")[0] == 1


def stale_staging_files_are_swept(base):
    state = os.path.join(base, "stay-awake-sessions")
    os.mkdir(state, 0o700)
    old = os.path.join(state, ".hold-old")
    new = os.path.join(state, ".hold-new")
    for path in (old, new):
        with open(path, "wb") as f:
            f.write(b"{}")
    two_hours_ago = time.time() - 7200
    os.utime(old, (two_hours_ago, two_hours_ago))
    assert run("write", state, b'{"sessions":[]}\n')[0] == 0
    assert names(state) == [".hold-new", "hold"], names(state)


check("a first read makes the directory, closed to everyone else", fresh_read_makes_the_directory)
check("a write reads back byte for byte, as a plain 0600 file", a_write_reads_back_as_written)
check("a link planted at hold is replaced, never followed", a_link_at_hold_is_replaced_not_followed)
check("a link at the old hold.tmp name is never written through", a_link_at_the_old_staging_name_is_left_alone)
check("a state directory that is a link is refused", a_linked_directory_is_refused)
check("a directory of ours that others could write is closed", a_loose_directory_of_ours_is_closed)
check("a directory above that others can write is refused", a_shared_directory_above_is_refused)
check("a sticky directory above, like /tmp, is fine", a_sticky_directory_above_is_fine)
check("a breadcrumb with other names or open to writes is ignored", a_breadcrumb_that_is_not_plainly_ours_is_ignored)
check("a pipe, a huge file or a directory at hold is ignored", odd_things_at_hold_are_ignored)
check("an empty payload or a relative path writes nothing", nothing_is_written_from_nothing)
check("staging files left by a killed writer are swept after an hour", stale_staging_files_are_swept)
print("%d checks passed" % passed)
