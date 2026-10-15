# discourse-cardwell-community

Cardwell's Discourse plugin for the **306 community**. It holds the few things that
have to run on the server rather than in the theme, one part at a time. The theme
lives in a separate, private repo; this plugin carries no brand, no data and no
secrets, which is why it can be public.

**Why one plugin and not several:** a plugin has a fixed cost whatever its size. It
is installed through `app.yml`, the first install and any `app.yml` change take a
container rebuild, and every part is retested on each Discourse upgrade. One repo
pays that cost once. Later parts arrive as pull requests here and deploy from
`/admin/upgrade`, without a full rebuild.

## Parts

| Part | What | Status |
| -- | -- | -- |
| 0 | Theme JavaScript compile limit (`AssetProcessor.timeout`), 15 s → configurable | Live, [306-565](https://linear.app/cardwell/issue/306-565) |
| 1 | Names in message history notices | Planned, [306-535](https://linear.app/cardwell/issue/306-535) |
| 2 | Hide paused, revoked and departed members' profiles | Planned, [306-498](https://linear.app/cardwell/issue/306-498) |
| 3 | Visit source for the week-two return metric | Planned, [306-498](https://linear.app/cardwell/issue/306-498) |
| 4 | Event details on topic list rows | Planned, [306-536](https://linear.app/cardwell/issue/306-536) |
| 5 | Activity and notification row details | Planned, [306-537](https://linear.app/cardwell/issue/306-537) |
| 6 | A private message's own "no access" page | Planned, [306-538](https://linear.app/cardwell/issue/306-538) |
| 7 | Directory moderation checks on the server | Planned, [306-528](https://linear.app/cardwell/issue/306-528) |
| 8 | Message membership facts on the server | Planned, [306-534](https://linear.app/cardwell/issue/306-534) |
| 8a | Tell the theme when moderators can read a message | Planned, [306-612](https://linear.app/cardwell/issue/306-612) |
| 9 | The landing page in one request | Planned, [306-556](https://linear.app/cardwell/issue/306-556) |
| 10 | Letter avatars show initials from the name | Planned, [306-587](https://linear.app/cardwell/issue/306-587) |
| 11 | Lucide-only icon pickers | In review, [306-609](https://linear.app/cardwell/issue/306-609) |

The parent issue is [306-533](https://linear.app/cardwell/issue/306-533); the
design home is PRD 2, _Platform approach, Cardwell community plugin_. The Linear
links are for the Cardwell team; they are private to that workspace.

### Part 0: theme JavaScript compile limit

Discourse compiles a theme's JavaScript inside a V8 sandbox (`AssetProcessor`, on
mini_racer) and terminates any script that runs past `AssetProcessor.timeout`. That
limit is 15 000 ms, hard-coded in `lib/asset_processor.rb`, with no site setting
or environment variable.

When the compile runs (checked in core at `dc24a92`): on a theme save whose
JavaScript changed (`Theme`'s `after_save`), and after a Discourse upgrade bumps
`Theme.compiler_version`, lazily, inside the first request that needs the theme's
JavaScript (`Theme.lookup_field`'s `extra_js` branch, reached from
`ApplicationHelper`). That first request can be any visitor's. The limit applies
per V8 call and that request may make several, so a higher limit gives each call
more room; the request itself is still bounded by the web worker, below. Every
other page view serves the compiled result and never compiles.

Measured on the community droplet on Oct 8 2026 (a DigitalOcean Regular shared
2 vCPU at 2.0 GHz; single-core `openssl speed sha256` ≈ 260 MB/s):

| | |
| -- | -- |
| 306 Community theme at `b5a0182` | 57 files, 622 KB in, 441 KB out |
| Compile on the droplet | 14.2 to 15.8 s |
| Same compiler and commit on a laptop | 1.9 s |
| Each failed theme update | `500` after about 20 s (15 s limit + git fetch and import) |

So the live theme already sits at the limit, and any JavaScript addition fails to
deploy while the site keeps serving the previous build.

**The ceiling is the web worker, not this setting.** `config/pitchfork.conf.rb`
kills a production request at 30 s, and a theme update spends about 5 s outside
the compile. A compile that runs to 25 s lands on the kill line with no margin,
and a killed worker is worse than a clean timeout. So the setting tops out at 25
and defaults to 24, which buys the theme about 60 percent more compile time than
core allows. Past that, the levers are a faster CPU (the droplet's shared vCPU is
about an eighth of a laptop core) or a smaller theme.

Settings, under the "Cardwell community" category (search the name in Admin →
Settings):

| Setting | Default | Notes |
| -- | -- | -- |
| `cardwell_community_enabled` | on | Off puts every part back to Discourse's defaults, with no rebuild. |
| `cardwell_theme_compile_timeout_seconds` | 24 | 15 to 25, see the ceiling above. |

A change applies to every web worker and Sidekiq without a restart.
`AssetProcessor.timeout` is per process and Discourse fires `site_setting_changed`
only in the process that saved, so the saving process applies the new limit and
publishes it on a MessageBus channel, and every live process applies it on
receipt. A process forked later inherited the boot-time value, so its fork hook
re-reads: Sidekiq from the settings (fresh by the time its hook fires), a web
worker from the channel's last message (its hook fires before
`SiteSetting.after_fork`, so its settings are still the mold's copy). Boot also
publishes the database's value, so after any restart the channel is the truth,
and the message is published with a ten-year backlog age so a worker respawned
weeks later still finds it. An in-place backup restore flushes Redis and swaps
the database without firing a setting change, so the plugin rebroadcasts on
Discourse's `site_settings_restored` event. What remains: anything that loses or
skips the channel's latest message between boot and a web worker's respawn (a
Redis flush by hand, Redis restarted from an older snapshot, a broadcast that
failed and was logged) leaves that worker on an older value until the next
change or restart.

### Part 11: Lucide-only icon pickers

The 306 Community theme ships every Lucide icon in its `icons-sprite`, each named
with the `lucide-` prefix, and every category, sidebar link, badge and group flair
on the site uses one. Discourse's icon pickers (category icon, sidebar links,
group flair, badges) still offer core's Font Awesome set next to them, so anyone
picking an icon could bring Font Awesome back.

Every picker fills its grid from `/svg-sprite/picker-search`, which the server
builds from `SvgSprite.picker_icon_ids`. A theme can't change a server response,
and hiding icons in the browser breaks the picker's paging: results come 100 at a
time in alphabetical order and `lucide-*` falls in the middle. So this part:

- **Filters the picker list** to ids starting with `lucide-`, after core's cached
  list, so a toggle applies on the next request. Only the pickers call
  `picker_icon_ids` (checked on 2026.10.0).
- **Leaves rendering alone.** Font Awesome stays in the sprite, because core UI
  still draws with it wherever the theme hasn't swapped an icon.
- **Busts the picker cache on toggle** by adding the setting to the picker-search
  ETag, so browsers refetch the list when it flips.

Checked against the live site on Oct 15 2026 in a throwaway `rails runner`
process that saved nothing: the picker list went from 3,651 icons to the 1,555
Lucide ones, "house" still finds `lucide-house`, and turning it off restores the
original list exactly.

| Setting | Default | Notes |
| -- | -- | -- |
| `cardwell_lucide_icon_pickers_enabled` | on | Off offers Font Awesome again, with no rebuild. Icons already in use don't change either way. |

## Install

In `containers/app.yml`, under `hooks: after_code:`, next to the existing
`docker_manager` clone:

```yaml
- exec:
    cd: $home/plugins
    cmd:
      - git clone --depth 1 https://github.com/discourse/docker_manager.git
      - git clone --depth 1 https://github.com/cardwellgroup/discourse-cardwell-community.git
```

Then `./launcher rebuild app`. Later updates to this plugin apply from
`/admin/upgrade`.

## On a Discourse upgrade

Each part leans on a core method or hook. After pinning a new Discourse version,
run this plugin's specs against it (CI runs them on every push against core's
`main`) and check the list below before rebuilding production:

- Part 0 guards `AssetProcessor` itself and its `timeout`, `timeout=` and `mutex`
  methods. If any is missing the plugin logs a warning at boot and leaves core's
  limit in place; any other error while setting the limit is logged, never
  raised. The specs additionally pin `AssetProcessor.reset_context` (called by
  core's setter). Not guarded, so check by hand: the event names
  `:web_fork_started`, `:sidekiq_fork_started` (both fired from
  `config/pitchfork.conf.rb`) and `:site_settings_restored`
  (`lib/backup_restore/restorer.rb`). A renamed event fails silently: forks
  keep the boot-time value, and a restored value is neither applied nor put back
  on the channel until the next change or restart. Also the fork events' order
  relative to `Discourse.after_fork`
  (web before it, in `pitchfork.conf.rb`; Sidekiq after it, in
  `lib/demon/base.rb`), `MessageBus.last_message` and `publish`'s
  `max_backlog_age` option, and the 30 s production worker timeout behind the
  setting's maximum.
- Part 11 prepends to `SvgSprite.picker_icon_ids(theme_id, only_available)` and
  `SvgSpriteController#stale?`. Check that the pickers are still the only caller
  of `picker_icon_ids` (if core starts rendering from it, the filter would hide
  Font Awesome icons in the UI) and that `icon_picker_search` still passes its
  ETag through `stale?`. The specs fail if either signature changes.

## Development

The specs run inside a Discourse checkout, the way every plugin's do:

```bash
# from a Discourse checkout with this repo cloned into plugins/
LOAD_PLUGINS=1 bin/rspec plugins/discourse-cardwell-community/spec
```

Lint matches Discourse's own: `bundle exec rubocop .` and
`bundle exec stree check $(git ls-files '*.rb')`. CI runs both plus the specs
through Discourse's shared
[plugin workflow](https://github.com/discourse/.github/blob/main/.github/workflows/discourse-plugin.yml).

Two rules keep this repo safe to publish:

- **No values in code.** Group names, thresholds and limits are site settings with
  defaults. Nothing here names a person, a key or an address.
- **No real data in specs.** Fixtures are synthetic. Seed data for the live site
  stays in the private theme repo.

## License

MIT, see [LICENSE](LICENSE).
