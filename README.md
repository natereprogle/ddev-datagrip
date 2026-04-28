[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/natereprogle/ddev-datagrip/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/natereprogle/ddev-datagrip/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/natereprogle/ddev-datagrip)](https://github.com/natereprogle/ddev-datagrip/commits)
[![release](https://img.shields.io/github/v/release/natereprogle/ddev-datagrip)](https://github.com/natereprogle/ddev-datagrip/releases/latest)

# DDEV DataGrip Add-On

## Overview
This Add-on allows you to open a DataGrip instance and connect to your local DDEV database without any manual configuration. It can also automatically use the MariaDB driver if it detects MariaDB instead of MySQL running in DDEV. As of 2025.2.5a, this Add-On now supports Postgres!

## Installation
```sh
ddev add-on get natereprogle/ddev-datagrip
ddev restart
```

After installation, make sure to commit the .ddev directory to version control.

> [!NOTE]
> DDEV doesn't support changing its DB credentials, so it should be well known that its default credentials are `db:db`. To configure DataGrip correctly, this Add-On will store these credentials in the `.ddev/datagrip` folder in your project. If you use tooling such as Gitleaks, be sure to configure it to prevent false positives.

## Usage
| Argument | Description |
|----------|-------------|
| `--database [database]` | Specify the database to connect to |
| `--reset` | Resets the Add-On's configuration, stored UUID, and the DataGrip project, including configuration and generated schemas. A new UUID is generated after reset. A manual refresh will be required upon next launch of DataGrip |
| `--auto-refresh [time in minutes]` | Enables auto-refresh in DataGrip. This only works if the datasource has been refreshed at least once. Minimum of 0.1 minutes (6 seconds), set to 0 to disable. Default is 1 minute |
| `--pg-pass` | Only applicable for DDEV projects using Postgres. This will utilize pgpass (`~/.pgpass`) instead of User & Password for connecting to the Postgres database. It is required to provide this argument each time you want to authenticate with pgpass unless configured to use pgpass by default via `ddev datagrip config` |
| `--no-defaults` | Ignores the defaults in the user configuration file |
| `--help` | Get command help |

Connect to your local default DDEV database
```sh
ddev datagrip
```

Connect to your local DDEV database using a specific database name
```sh
ddev datagrip --database my-db
```

Reset the Add-On, which will remove any user-generated configuration, regenerate the data source UUID, and wipe and recreate the DataGrip project (note this will require you to manually refresh the datasource once DataGrip is launched).
```sh
ddev datagrip --reset
```

Set the auto-refresh delay to 30 seconds instead of 1 minute
```sh
ddev datagrip --auto-refresh 0.5
```

Use pgpass when connecting to a Postgres DB
```sh
ddev datagrip --pg-pass
```

Ignore the user-defined default settings and launch with the Add-On's default settings
```sh
ddev datagrip --no-defaults
```

## Configuration
As of Add-On version 2025.2.5b, the Add-On supports configuration. Available configurations options are:
| Option | Type | Usage | Hardcoded Fallback |
|--------|------|-------|--------------------|
| `pg-pass` | bool | Whether to use `~/.pgpass` for Postgres auth (equivalent to passing `--pg-pass` every time) | `false` |
| `default-database` | string | Default database to connect to (equivalent to passing `--database <name>`) | `"db"` |
| `auto-refresh` | number | Refresh interval in minutes (equivalent to `--auto-refresh <n>`) | `1` |
| `datagrip-version` | string | Pin the DataGrip version used to select the configuration script. Set this if auto-detection fails or detects the wrong installation (e.g. multiple DataGrip versions installed) | *(auto-detected)* |

### Version detection

The Add-On automatically detects your installed DataGrip version by scanning JetBrains Toolbox's `state.json`, well-known installation paths, and the `datagrip` binary on your `PATH`. If detection succeeds, no configuration is needed.

If detection fails (DataGrip is installed in a non-standard location, or the Add-On can't read the install metadata), the command will exit with an error and tell you to set the version manually:

```sh
ddev datagrip config set datagrip-version 2025.2.5
```

If you have multiple DataGrip installations and the wrong one is detected, the configured value always takes precedence. A warning is shown if the configured version differs from the detected version so you can `unset` it once the detection issue is resolved:

```sh
ddev datagrip config unset datagrip-version
```

This Add-On will create between 1 and 2 configuration files, depending on if any user-defined defaults are provided
1. `.ddev/datagrip/config.yaml` -- This file is always generated and only contains the `uuid` of the data source (generated on first run). Any subsequent execution of the `ddev datagrip` command will use this UUID. **This should never be modified manually**. If the UUID must be regenerated for any reason, pass `--reset` (note this will reset all configuration and remove any project files, including SQL scripts and scratch files). 
2. `.ddev/datagrip/.user-config.yaml` -- This file is generated only when a user directly sets a default via `ddev datagrip config set <key> <value>`. As well, a `.gitignore` is generated next to this file which ignores it so it is not commited to the repo. This allows for the `uuid` to be commited, but user preferences to remain local. This file and the `.gitignore` will remain even if all options are unset. They are removed if `--reset` is provided.

Configuration can be modified by the user by using the `ddev datagrip config <subcommand> [args]` command. Use `ddev datagrip config` to learn what configuration options are available and how to view and/or modify them.

## Additional Features
A known limitation of DataGrip is that it cannot automatically connect to a database on launch. The only way around this is either via the IDE Scripting Engine, writing your own plugin, or using an already-existing 3rd Party Plugin.

# Update Philosophy
JetBrains reserves the right to change how DataGrip is configured at any time. To support both old and new DataGrip versions simultaneously, this Add-On uses a version manifest (`commands/host/datagrip-lib/versions.json`) that maps DataGrip version ranges to version-specific configuration scripts in `commands/host/datagrip-lib/versions/`.

When you run `ddev datagrip`, the Add-On detects your installed DataGrip version and selects the highest manifest entry whose version is ≤ your installed version. For example, with a manifest of `2025.2.5` and `2026.1`, a user on DataGrip 2025.3.0 gets the `2025.2.5` script, while a user on 2026.1 or newer gets the `2026.1` script. Versions below the oldest supported entry are routed to `unsupported.sh`, which exits with an error.

New entries are added to the manifest only when JetBrains changes the DataGrip configuration format in a way that requires it. Versions that work identically to a prior release continue to use the existing script without any changes to the manifest.

## Adding support for a new DataGrip version

1. **Check whether the XML format changed.** Open the new DataGrip version, connect to a DDEV project manually, and compare the generated `.idea/dataSources.xml` and `.idea/dataSources.local.xml` against the template in `commands/host/datagrip-lib/versions/2025.2.5.sh`. If the structure is identical, no new script is needed — the existing entry already covers the new version via the "highest matching minimum" rule.

2. **If the format changed**, create a new script at `commands/host/datagrip-lib/versions/<version>.sh` (e.g. `2026.1.sh`). Copy the nearest existing script as a starting point and update the XML template to match what DataGrip now expects.

3. **Add an entry to `commands/host/datagrip-lib/versions.json`** using the new DataGrip version as the key and the script filename as the value:
   ```json
   {
       "2026.1": "2026.1.sh",
       "2025.2.5": "2025.2.5.sh",
       "<2025.2.5": "unsupported.sh"
   }
   ```
   Keys are matched from highest to lowest, so order within the JSON object does not affect behaviour — but keeping them in descending order makes the file easier to read.

4. **Add the new script to `install.yaml`** under `project_files` and add a `chmod +x` line for it in `post_install_actions`.

5. **Update `unsupported.sh`** if the minimum supported DataGrip version has changed, so the error message reflects the new floor.

Add-On releases use **CalVer** (`YYYY.0M.0D`), where the version is simply the date the release was published - for example, `2026.04.27`. This makes it easy to tell how recent a release is without implying anything about DataGrip compatibility. If more than one release is published on the same day, a numeric suffix is appended: `2026.04.27.1`, `2026.04.27.2`, and so on.

# Known Issues & Limitations
## Initial Data Refresh
Unlike other SQL tools like Sequel Ace, SQL Pro, and others which can be launched with CLI arguments to immediately connect to a Database, DataGrip requires a "Project". A Project is a directory which contains several configuration files, including `./.idea/dataSources.xml` and the DB schema, located in `./.idea/dataSources/` and generated by DataGrip automatically. Projects must be created with the DataGrip GUI. When DataGrip connects to a Data Source, it does so by creating a "Session". Sessions are created when various actions in DataGrip occur, such as (but not limited to) adding a Data Source to a Project. Sessions, among other things, also trigger Introspection.

In order to support DataGrip *at all*, this Add-On creates a Project and the necessary configuration files for you within the `.ddev/datagrip` directory. These files are based on a manual review of "real" datagrip configuration files and contain only the bare minimum configuration necessary to make DataGrip work with DDEV. However, because DataGrip was never intended to be configured this way, this **skips several steps** that DataGrip typically performs on its own, the most important of which being the initial introspection, schema generation, and caching. Because these steps aren't executed, Automatic Introspection also will never trigger and subsequent launches of DataGrip will **never** generate schema or trigger introspection, either. Unfortunately, [this behavior is by design](https://www.jetbrains.com/help/datagrip/2026.1/connecting-to-a-database.html?utm_source=product&utm_medium=link&utm_campaign=TBA#session:~:text=tip-,On,projects%2E). *This is a limitation of DataGrip, not DDEV or this Add-On*. We hope this can be improved in the future, but as of DataGrip 2026.1, it is not an option.

<details>
<summary>LivePlugin Workaround</summary>

This Add-On provides a workaround to this limitation which utilizes the [LivePlugin](https://plugins.jetbrains.com/plugin/7282-liveplugin) plugin. LivePlugin, while not authored by JetBrains, is somewhat officially(?) endorsed by them [in their IntelliJ Platform Plugin SDK documentation](https://plugins.jetbrains.com/docs/intellij/plugin-alternatives.html#liveplugin). LivePlugin allows for writing and running plugins at runtime without IDE restarts. By default, LivePlugin will automatically run any plugins that exist in the `.live-plugins/` directory within a project. When you install this Add-On, a `.kts` script is copied into the `.ddev/datagrip/.live-plugins` directory, which is seen as a LivePlugin plugin and automatically executed at launch which refreshes **all** data sources in the project.

**You are not required to utilize the LivePlugin plugin!** The Add-On will operate 100% fine without it. However, doing so will improve your experience with this Add-On greatly. To use this, run `ddev datagrip autorefresh`. The `autorefresh` subcommand will install the plugin via the native `installPlugins` argument in the datagrip CLI launcher, but you can always manually refresh whenever needed or install the plugin manually at a later time.

> [!NOTE]
> Please keep in mind this *is* a workaround and **not an official solution** to the problem. The reliance on a 3rd party plugin means it is not guaranteed to work forever. Please report any issues with LivePlugin itself to the developer.
 
</details>

## Cleartext DB Credentials
DDEV uses `db:db` as its DB credentials. As it's meant for local development, they've also stated they have [no plans to allow changing this](https://github.com/ddev/ddev/issues/5723). This add-on stores DDEV's DB credentials in plaintext in the JDBC URL within `dataSources.xml`. Certain tools, like Gitleaks, may pick up on these credentials and throw a fit. You will need to make adjustments to your tooling if storing these credentials in plaintext is an issue.

The only exception to this is if you use pgpass for authentication when using a Postgres database. However, tooling may still pick up on the credentials hardcoded in the Add-On itself, and this is not something that can be resolved.

## Incorrect configuration displayed after running `ddev datagrip` while DataGrip is running
Sometimes, when `ddev datagrip` is run while DataGrip is already open, certain configuration values will not reflect their "true" value until DataGrip is restarted. An example of this can be found if you are using Postgres and typically use `ddev datagrip --pg-pass` to utilize .pgpass when authenticating. If you decide to execute `ddev datagrip` instead, which will use User & Password authentication, the Data Sources panel will show pgpass as the Authentication method but DataGrip will still use User & Password instead to authenticate. A restart of DataGrip is required to show the correct datasource properties.

It is recommended that you exit DataGrip *fully* before running `ddev datagrip` to prevent any issues or quirks.
