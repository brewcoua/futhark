import '_common.just'

# Build the documentation book into docs/book
build:
    mdbook build docs

# Serve the documentation with live reload
serve:
    mdbook serve docs --open
