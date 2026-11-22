"""Verify the project-level UI skill snapshot offline."""

import hashlib
import json
from pathlib import Path
import re


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify(agents):
    manifest = json.loads((agents / "skills-lock.json").read_text(encoding="utf-8"))
    skills = agents / "skills"
    licenses = agents / "skill-licenses"
    if skills.is_symlink() or licenses.is_symlink():
        raise ValueError("Skill and license roots must be regular directories")
    if {entry.name for entry in skills.iterdir()} != manifest["skills"].keys():
        raise ValueError("Skill directories differ from the manifest")

    for source in manifest["sources"].values():
        license_file = agents / source["license"]
        if license_file.is_symlink() or digest(license_file.read_bytes()) != source["license_sha256"]:
            raise ValueError(f"License integrity mismatch: {license_file}")

    file_count = 0
    for name, expected in manifest["skills"].items():
        root = skills / name
        if root.is_symlink():
            raise ValueError(f"Skill is a symlink: {root}")
        if expected["source"] not in manifest["sources"]:
            raise ValueError(f"Unknown upstream source: {name}")
        records = {}
        for path in root.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"Unexpected symlink: {path}")
            if path.suffix == ".pyc" and path.parent.name == "__pycache__":
                continue
            if path.is_file():
                records[path.relative_to(root).as_posix()] = digest(path.read_bytes())
        index = "".join(f"{path}\t{sha}\n" for path, sha in sorted(records.items()))
        if len(records) != expected["files"] or digest(index.encode()) != expected["tree_sha256"]:
            raise ValueError(f"Skill integrity mismatch: {name}")
        frontmatter = (root / "SKILL.md").read_text(encoding="utf-8").split("---", 2)[1]
        if not re.search(rf"^name:\s*{re.escape(name)}\s*$", frontmatter, re.MULTILINE):
            raise ValueError(f"Skill front matter name mismatch: {name}")
        file_count += len(records)
    return len(manifest["skills"]), file_count


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    count, files = verify(root / ".agents")
    print(f"Verified {count} skills and {files} skill files, with upstream licenses.")
