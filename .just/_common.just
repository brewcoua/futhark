# Settings every module shares. `import` is a textual splice, so these apply to the importing
# module — unlike `mod`, which would nest them behind another namespace.

# A module recipe otherwise runs in the directory holding its own source file, i.e. .just/.
# Relative, not justfile_directory(): settings are a const context and cannot call functions.
set working-directory := '..'

# Real bash, so every recipe gets pipefail whether or not it carries a shebang.
set shell := ['bash', '-euo', 'pipefail', '-c']

# Comments in a recipe body are documentation, not commands to echo back at the operator.
# Shebang recipes are unaffected, which is what we want — there the comments are part of the script.
set ignore-comments
