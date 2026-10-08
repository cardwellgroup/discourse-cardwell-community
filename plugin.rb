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
  CardwellCommunity::CompileTimeout.apply!

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
  # stale copy. That rules out the plugin's `on` wrapper.
  # rubocop:disable Discourse/Plugins/UsePluginInstanceOn
  DiscourseEvent.on(:web_fork_started) { CardwellCommunity::CompileTimeout.resync! }
  DiscourseEvent.on(:sidekiq_fork_started) { CardwellCommunity::CompileTimeout.resync! }
  # rubocop:enable Discourse/Plugins/UsePluginInstanceOn
end
