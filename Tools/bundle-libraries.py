#!/usr/bin/env python3
"""Copies the Homebrew libraries an app links against into its Contents/Frameworks, with the libraries they need in
turn, and points every link at the copies, so the app runs on a Mac without Homebrew. Also copies each library's
licence files to Contents/Resources/Licenses and lists the libraries, their versions, licences and source addresses
in Contents/Resources/Licenses/Libraries.txt.

Usage: Tools/bundle-libraries.py "build/package/HighCamp.app"
"""
import json
import os
import shutil
import subprocess
import sys

BREW = "/opt/homebrew"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def links(path):
    """The libraries a Mach-O file loads, as written in it (its own id left out)."""
    own = run("otool", "-D", path).splitlines()[1:]
    found = []
    for line in run("otool", "-L", path).splitlines()[1:]:
        reference = line.strip().split(" (")[0]
        if reference and reference not in own:
            found.append(reference)
    return found


def rpaths(path):
    lines = run("otool", "-l", path).splitlines()
    found = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            found.append(lines[index + 2].strip().split("path ", 1)[1].rsplit(" (offset", 1)[0])
    return found


def resolve(reference, loader):
    """The file a reference in `loader` (a real path) points at, or None for system libraries."""
    folder = os.path.dirname(loader)
    if reference.startswith(BREW):
        return os.path.realpath(reference)
    if reference.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(folder, reference[len("@loader_path/"):]))
    if reference.startswith("@rpath/"):
        name = reference[len("@rpath/"):]
        for rpath in rpaths(loader) + ["@loader_path"]:
            base = rpath.replace("@loader_path", folder)
            candidate = os.path.join(base, name)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        raise SystemExit(f"cannot find {reference} for {loader}")
    return None


def main(app):
    executable = os.path.join(app, "Contents/MacOS/BaseCampApp")
    frameworks = os.path.join(app, "Contents/Frameworks")
    os.makedirs(frameworks, exist_ok=True)

    # Every Homebrew library needed, by real path, with the name it gets in the bundle.
    names = {}
    pending = [r for r in (resolve(x, executable) for x in links(executable)) if r]
    while pending:
        library = pending.pop()
        if library in names:
            continue
        name = os.path.basename(library)
        if name in names.values():
            raise SystemExit(f"two libraries named {name}")
        names[library] = name
        pending += [r for r in (resolve(x, library) for x in links(library)) if r and r not in names]

    def relink(path, source):
        """Points every Homebrew link of the file at `path` (copied from `source`) at the bundled copy."""
        changes = []
        for reference in links(path):
            target = resolve(reference, source)
            if target:
                changes += ["-change", reference, "@rpath/" + names[target]]
        if changes:
            run("install_name_tool", *changes, path)

    for library, name in names.items():
        copy = os.path.join(frameworks, name)
        shutil.copyfile(library, copy)
        os.chmod(copy, 0o755)
        relink(copy, library)
        run("install_name_tool", "-id", "@rpath/" + name, copy)
        for rpath in rpaths(copy):
            run("install_name_tool", "-delete_rpath", rpath, copy)
        run("install_name_tool", "-add_rpath", "@loader_path", copy)

    relink(executable, executable)
    for rpath in rpaths(executable):
        if rpath.startswith(BREW):
            run("install_name_tool", "-delete_rpath", rpath, executable)
    if "@executable_path/../Frameworks" not in rpaths(executable):
        run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", executable)

    # Licences, from each library's Homebrew keg, and the list of what is included.
    licenses = os.path.join(app, "Contents/Resources/Licenses")
    os.makedirs(licenses, exist_ok=True)
    # A keg is /opt/homebrew/Cellar/FORMULA/VERSION.
    kegs = sorted({"/" + os.path.join(*library.split(os.sep)[1:6]) for library in names if library.startswith(BREW + "/Cellar/")})
    formulas = [keg.split(os.sep)[4] for keg in kegs]
    info = {f["name"]: f for f in json.loads(run("brew", "info", "--json=v2", *formulas))["formulae"]}
    lines = ["Libraries included in HighCamp, from Homebrew, with their licences and where their source code is.",
             "Their licence files are in the folders next to this one.", ""]
    for keg in kegs:
        formula, version = keg.split(os.sep)[4:6]
        folder = os.path.join(licenses, f"{formula} {version}")
        os.makedirs(folder, exist_ok=True)
        for entry in os.listdir(keg):
            if entry.upper().startswith(("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "AUTHORS")):
                source = os.path.join(keg, entry)
                if os.path.isfile(source):
                    shutil.copyfile(source, os.path.join(folder, entry))
        details = info.get(formula, {})
        license = details.get("license") or "see the licence files"
        url = details.get("urls", {}).get("stable", {}).get("url") or details.get("homepage", "")
        lines.append(f"{formula} {version}: {license}. Source: {url}")
    with open(os.path.join(licenses, "Libraries.txt"), "w") as file:
        file.write("\n".join(lines) + "\n")

    leftover = [f for f in [executable] + [os.path.join(frameworks, n) for n in names.values()]
                if any(r.startswith(BREW) for r in links(f) + rpaths(f))]
    if leftover:
        raise SystemExit(f"still linked to Homebrew: {leftover}")
    print(f"Bundled {len(names)} libraries from {len(kegs)} Homebrew packages")


if __name__ == "__main__":
    main(sys.argv[1])
