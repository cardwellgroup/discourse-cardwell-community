# frozen_string_literal: true

module CardwellCommunity
  # Part 0 (306-565). Discourse compiles a theme's JavaScript inside a V8
  # sandbox (AssetProcessor, backed by mini_racer) and terminates any script
  # that runs past AssetProcessor.timeout: 15 000 ms, hard-coded, with no site
  # setting or environment variable. On the community droplet (a shared 2 vCPU
  # at 2.0 GHz) the 306 Community theme already takes 14 to 16 s to compile, so
  # every theme update that changes JavaScript fails with
  # AssetProcessor::TimeoutError and the site keeps serving the previous build.
  # Measured Oct 8 2026; the README has the numbers.
  #
  # When the compile runs (core at dc24a92): on a theme save whose JavaScript
  # changed (Theme's after_save in app/models/theme.rb), and after a Discourse
  # upgrade bumps Theme.compiler_version, lazily, inside the first request that
  # needs the theme's JavaScript (Theme.lookup_field's extra_js branch, reached
  # from ApplicationHelper). That first request can be any visitor's. The limit
  # applies per V8 call, and that request may make several, so a higher limit
  # gives each call more room; the request itself is still bounded by the web
  # worker below.
  #
  # The ceiling is the web worker, not this setting: config/pitchfork.conf.rb
  # kills a production request at 30 s, and a theme update spends about 5 s
  # outside the compile (git fetch and import). At 25 s the margin is zero,
  # which is why 24 is the default. Past that, the lever is a faster CPU or a
  # smaller theme.
  #
  # AssetProcessor.timeout is a per-process value. A site-setting save fires
  # :site_setting_changed only in the process that handled the save; the other
  # web workers and Sidekiq learn the new value through MessageBus and never
  # fire the event. So the handler broadcasts the new limit on this plugin's
  # own channel and every live process applies it on receipt (a no-op for the
  # sender). A process forked later inherits the mold's boot-time value and
  # never saw the broadcast. Sidekiq's fork hook runs after its settings are
  # reloaded, so it re-reads them (apply!). The web fork hook runs before
  # SiteSetting.after_fork, so its settings are the mold's stale copy; it
  # re-reads the channel's last message instead (resync!). Boot also
  # broadcasts, so after any restart (including a rebuild on a restored
  # backup) the channel carries the database's value, and the message is
  # published with a backlog age long enough to outlive any uptime.
  module CompileTimeout
    CHANNEL = "/cardwell-community/compile-timeout"
    # message_bus's Redis backend expires a channel backlog after
    # max_backlog_age (7 days by default). A worker respawned later than that
    # would find nothing and fall back to the mold's copy, so the broadcast
    # asks for a backlog that outlives any realistic uptime.
    BACKLOG_AGE_SECONDS = 10 * 365 * 24 * 60 * 60
    FALLBACK_CORE_DEFAULT_MS = 15_000
    SETTINGS = %i[cardwell_theme_compile_timeout_seconds].freeze

    def self.watches?(setting_name)
      SETTINGS.include?(setting_name.to_sym)
    end

    # Core's own value, read before this plugin first changes it, so turning
    # the plugin off restores whatever core ships rather than a copied number.
    def self.core_default_ms
      @core_default_ms ||= available? ? AssetProcessor.timeout : FALLBACK_CORE_DEFAULT_MS
    end

    def self.desired_ms
      return core_default_ms unless SiteSetting.cardwell_community_enabled
      SiteSetting.cardwell_theme_compile_timeout_seconds * 1000
    end

    # This process only, from the settings this process can see: a Sidekiq
    # fork (its settings are fresh by the time its hook fires) and resync!'s
    # fallback.
    def self.apply!
      apply_ms!(desired_ms)
    end

    # This process, then every other live one. Boot calls this too, so the
    # channel carries the database's value after any restart.
    def self.broadcast!
      ms = desired_ms
      apply_ms!(ms)
      MessageBus.publish(CHANNEL, { "ms" => ms }, max_backlog_age: BACKLOG_AGE_SECONDS)
    rescue StandardError => e
      # At boot a bus failure must not stop the site; on a save, the change has
      # already committed and a bus failure must not 500 it.
      Rails.logger.warn("#{PLUGIN_NAME}: could not broadcast the compile limit: #{e.message}")
    end

    # A freshly forked web worker: the last broadcast wins over the inherited
    # boot value, because the settings this hook can read are the mold's stale
    # copy. With nothing usable on the channel (Redis lost it since boot), the
    # mold's copy is the best information there is.
    def self.resync!
      last = MessageBus.last_message(CHANNEL)
      receive(last&.data) || apply!
    rescue StandardError => e
      Rails.logger.warn("#{PLUGIN_NAME}: could not resync the compile limit: #{e.message}")
    end

    # The MessageBus payload arrives with string keys. Only the server publishes
    # on this channel, but a malformed payload must still not raise here.
    # Returns whether the payload carried a usable limit, so resync! knows
    # not to fall back.
    def self.receive(data)
      ms = data.is_a?(Hash) ? Integer(data["ms"], exception: false) : nil
      return false unless ms&.positive?
      apply_ms!(ms)
      true
    end

    def self.apply_ms!(ms)
      # Nothing here may raise at boot: a renamed core constant or method has
      # to leave core's limit in place, not take the site down.
      unless available?
        Rails.logger.warn("#{PLUGIN_NAME}: AssetProcessor API changed; compile limit left as is")
        return
      end
      core_default_ms
      return if AssetProcessor.timeout == ms

      # The setter disposes the live V8 context so the next call builds one
      # with the new limit. Take AssetProcessor's own mutex first: v8_call holds
      # it per call, so a reset lands between calls and never under one. The
      # only other reader of the context, the pre-fork warm-up in
      # lib/discourse.rb, runs at boot before any setting can change. Whoever
      # calls this (the admin's save, a process's MessageBus subscriber thread,
      # a fork hook) may wait for one in-flight call, up to the limit itself.
      AssetProcessor.mutex.synchronize { AssetProcessor.timeout = ms }
    rescue StandardError => e
      Rails.logger.warn("#{PLUGIN_NAME}: could not set the compile limit: #{e.class}: #{e.message}")
    end

    def self.available?
      defined?(::AssetProcessor) && AssetProcessor.respond_to?(:timeout=) &&
        AssetProcessor.respond_to?(:timeout) && AssetProcessor.respond_to?(:mutex)
    end
  end
end
