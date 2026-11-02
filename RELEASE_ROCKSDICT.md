# Releasing `rocksdict`

This adds to the SKILL conda-release (`.claude/skills/conda-release/SKILL.md`).

`release-rocksdict.yml`'s `pythons` input: for a new version, the CPython versions the newest rocksdict on the
channel is built for (`conda search --override-channels -c https://conda.qiyuan.me rocksdict`); when adding a CPython
version to a version already published, only the new one (the input's comment says why).
