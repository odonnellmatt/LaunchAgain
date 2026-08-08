# LaunchAgain documentation site

This public repository contains only the de-identified LaunchAgain documentation site.
Application source, test fixtures, research evidence, diagnostics, profiles, local paths,
and maintainer identity are intentionally excluded.

The canonical site files live in the private source repository's `site/` directory. A
maintainer publishes that exact allow-listed payload with `Scripts/publish-pages.sh` after
each documented patch. The Pages workflow deploys only `public/`.

See the [project documentation site](https://odonnellmatt.github.io/LaunchAgain-site/).
