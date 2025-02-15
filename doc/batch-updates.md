# Batch updates {#batch-updates}

nixpkgs-update supports batch updates via the `update-list`
subcommand.

## Update-List tutorial

1. Setup [hub](https://github.com/github/hub) and give it your GitHub
   credentials, so it saves an oauth token. This allows nixpkgs-update
   to query the GitHub API.

2. Clone this repository and build `nixpkgs-update`:
    ```bash
    git clone https://github.com/ryantm/nixpkgs-update && cd nixpkgs-update
    nix-build
    ```

3. To test your config, try to update a single package, like this:

   ```bash
   ./result/bin/nixpkgs-update update "pkg oldVer newVer update-page"`

   # Example:
   ./result/bin/nixpkgs-update update "tflint 0.15.0 0.15.1 repology.org"`
   ```

   replacing `tflint` with the attribute name of the package you actually want
   to update, and the old version and new version accordingly.

   If this works, you are now setup to hack on `nixpkgs-update`! If
   you run it with `--pr`, it will actually send a pull request, which
   looks like this: https://github.com/NixOS/nixpkgs/pull/82465


4. If you'd like to send a batch of updates, get a list of outdated packages and
   place them in a `packages-to-update.txt` file:

  ```bash
  ./result/bin/nixpkgs-update fetch-repology > packages-to-update.txt
  ```

  There also exist alternative sources of updates, these include:

   - PyPI, the Python Package Index:
     [nixpkgs-update-pypi-releases](https://github.com/jonringer/nixpkgs-update-pypi-releases)
   - GitHub releases:
     [nixpkgs-update-github-releases](https://github.com/synthetica9/nixpkgs-update-github-releases)

5. Run the tool in batch mode with `update-list`:

  ```bash
  ./result/bin/nixpkgs-update update-list
  ```
