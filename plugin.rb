# frozen_string_literal: true

# name: discourse-cardwell-community
# about: The few parts of Cardwell's 306 community that have to run on the server.
# version: 0.1.0
# authors: Cardwell Group
# url: https://github.com/cardwellgroup/discourse-cardwell-community
# required_version: 2.7.0

enabled_site_setting :cardwell_community_enabled

module ::CardwellCommunity
  PLUGIN_NAME = "discourse-cardwell-community"
end

require_relative "lib/cardwell_community/compile_timeout"

after_initialize do
  # Apply here and put the database's value on the channel, so that forks
  # after any restart read the truth and not a broadcast from before it.
  CardwellCommunity::CompileTimeout.broadcast!

  # Other live processes apply the broadcast; see the module comment for why a
  # setting change cannot reach them any other way.
  MessageBus.subscribe(CardwellCommunity::CompileTimeout::CHANNEL) do |message|
    CardwellCommunity::CompileTimeout.receive(message.data)
  end

  # `on` fires only while the plugin is enabled, which is right for the seconds
  # setting. `on_enabled_change` fires either way, so turning the plugin off
  # puts core's limit back.
  on(:site_setting_changed) do |name, _old_value, _new_value|
    CardwellCommunity::CompileTimeout.broadcast! if CardwellCommunity::CompileTimeout.watches?(name)
  end
  on_enabled_change { CardwellCommunity::CompileTimeout.broadcast! }

  # A process forked after a change inherits the mold's boot-time limit and
  # missed the broadcast. These must run whatever the enabled flag says: the
  # last broadcast may be the one that turned the plugin off, and the web hook
  # fires before SiteSetting.after_fork, so `enabled?` there reads the mold's
  # stale copy. That rules out the plugin's `on` wrapper. Sidekiq's hook fires
  # after Discourse.after_fork, so its settings are fresh and it re-reads them.
  # An in-place backup restore flushes Redis (the channel with it), swaps the
  # database and refreshes settings without firing :site_setting_changed, so
  # the restored value has to be applied and put back on the channel by hand.
  # rubocop:disable Discourse/Plugins/UsePluginInstanceOn
  DiscourseEvent.on(:web_fork_started) { CardwellCommunity::CompileTimeout.resync! }
  DiscourseEvent.on(:sidekiq_fork_started) { CardwellCommunity::CompileTimeout.apply! }
  DiscourseEvent.on(:site_settings_restored) { CardwellCommunity::CompileTimeout.broadcast! }
  # rubocop:enable Discourse/Plugins/UsePluginInstanceOn
end
