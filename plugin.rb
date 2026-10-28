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
require_relative "lib/cardwell_community/lucide_icon_pickers"
require_relative "lib/cardwell_community/initials_avatars"
require_relative "lib/cardwell_community/message_names"
require_relative "lib/cardwell_community/cohort_space_sidebar"
require_relative "lib/cardwell_community/visit_source"
require_relative "lib/cardwell_community/profile_hiding"
require_relative "lib/cardwell_community/directory_checks"

after_initialize do
  reloadable_patch do
    SvgSprite.singleton_class.prepend(CardwellCommunity::LucideIconPickers::SvgSpriteExtension)
    SvgSpriteController.prepend(CardwellCommunity::LucideIconPickers::SvgSpriteControllerExtension)
    User.singleton_class.prepend(CardwellCommunity::InitialsAvatars::UserExtension)
    ComposerMessagesController.prepend(
      CardwellCommunity::MessageNames::ComposerMessagesControllerExtension,
    )
    PushNotificationPusher.singleton_class.prepend(
      CardwellCommunity::VisitSource::PushNotificationPusherExtension,
    )
    ApplicationController.include(CardwellCommunity::VisitSource::ControllerExtension)
    Guardian.prepend(CardwellCommunity::ProfileHiding::GuardianExtension)
    DirectoryItemsQuery.prepend(CardwellCommunity::ProfileHiding::DirectoryItemsQueryExtension)
    DirectoryItemsQuery.prepend(CardwellCommunity::DirectoryChecks::DirectoryItemsQueryExtension)
    UserSearch.prepend(CardwellCommunity::ProfileHiding::UserSearchExtension)
    Search.prepend(CardwellCommunity::ProfileHiding::SearchExtension)
    GroupsController.prepend(CardwellCommunity::ProfileHiding::GroupsControllerExtension)
    Group.prepend(CardwellCommunity::ProfileHiding::GroupExtension)
    BasicGroupSerializer.prepend(CardwellCommunity::ProfileHiding::BasicGroupSerializerExtension)
    ComposerController.prepend(CardwellCommunity::ProfileHiding::ComposerControllerExtension)
    UserBadgesController.prepend(CardwellCommunity::ProfileHiding::UserBadgesControllerExtension)
    BadgeSerializer.prepend(CardwellCommunity::ProfileHiding::BadgeSerializerExtension)
    BadgesController.prepend(CardwellCommunity::ProfileHiding::BadgesControllerExtension)
  end

  # Part 1: names next to the handles on message notices; see MessageNames.
  TopicView.on_preload { |topic_view| CardwellCommunity::MessageNames.preload(topic_view) }

  add_to_serializer(
    :post,
    :action_code_who_name,
    include_condition: -> { action_code_who_name.present? },
  ) do
    # include_condition calls this too; a post outside a TopicView looks its
    # name up, so that lookup runs once.
    next @cardwell_who_name if defined?(@cardwell_who_name)
    @cardwell_who_name =
      CardwellCommunity::MessageNames.name_for(
        object.action_code,
        post_custom_fields["action_code_who"],
        scope,
        topic_view: @topic_view,
        post_id: object.id,
      )
  end

  add_to_serializer(
    :user_action,
    :action_code_who_name,
    include_condition: -> { action_code_who_name.present? },
  ) do
    next @cardwell_who_name if defined?(@cardwell_who_name)
    @cardwell_who_name =
      CardwellCommunity::MessageNames.name_for(object.action_code, object.action_code_who, scope)
  end

  # Part 12: a cohort space follows its group's membership into the sidebar;
  # see CohortSpaceSidebar. `on` fires only while the plugin is enabled.
  on(:user_added_to_group) do |user, group, **_opts|
    CardwellCommunity::CohortSpaceSidebar.added_to_group(user, group)
  end
  on(:user_removed_from_group) do |user, group|
    CardwellCommunity::CohortSpaceSidebar.removed_from_group(user, group)
  end
  on(:site_setting_changed) do |name, old_value, new_value|
    if name.to_s == "cardwell_cohort_space_categories"
      CardwellCommunity::CohortSpaceSidebar.setting_changed(old_value, new_value)
    end
  end

  # Part 2: hidden members out of header and full-page search; see ProfileHiding.
  register_modifier(:search_user_search) do |users|
    CardwellCommunity::ProfileHiding.filter_request_users(users)
  end

  # Part 7: moderation state on each directory row, for staff; see DirectoryChecks.
  add_to_serializer(
    :directory_item,
    :cardwell_staff,
    include_condition: -> { scope.is_staff? && CardwellCommunity::DirectoryChecks.on? },
  ) { CardwellCommunity::DirectoryChecks.staff_fields(object.user, object.user_stat) }

  # Every row the checks ran on says so, for everyone: the theme shows members
  # no directory without it, so it never lists suspended people by mistake.
  add_to_serializer(
    :directory_item,
    :cardwell_checked,
    include_condition: -> { CardwellCommunity::DirectoryChecks.on? },
  ) { true }

  # Part 3: tag links in summary and notification emails; see VisitSource.
  on(:before_email_send) do |message, email_type|
    CardwellCommunity::VisitSource.tag_email(message, email_type)
  end

  require_relative "lib/cardwell_community/initials_avatars_controller"
  require_relative "lib/cardwell_community/directory_silenced_controller"
  CardwellCommunity::InitialsAvatars.cleanup_old

  # Under /letter_avatar/ so nginx caches it like core's letter avatars; see
  # InitialsAvatars for why the four segments can't collide with core's route.
  Discourse::Application.routes.append do
    get "letter_avatar/cardwell/:username/:color/:size.png" =>
          "cardwell_community/initials_avatars#show",
        :constraints => {
          username: RouteFormat.username,
          color: /\h{6}/,
          size: /\d+/,
          format: :png,
        }
    get "cardwell/directory/silenced" => "cardwell_community/directory_silenced#index"
  end

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
