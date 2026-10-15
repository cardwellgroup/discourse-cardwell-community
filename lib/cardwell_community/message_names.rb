# frozen_string_literal: true

module CardwellCommunity
  # Part 1 (306-535). The history lines in a message ("Dana Whitfield left this
  # message", "Added Pat Lee to this message") should lead with the person's
  # name, as the rest of the community does. Core stores only the handle with
  # each notice (the post's action_code_who custom field) and builds every line
  # from it in the browser, so a text override can't reach it.
  #
  # The server half sends the name next to the handle:
  #   * action_code_who_name on posts, looked up once per page of posts
  #     through TopicView's per-post store, and on activity stream rows;
  #   * a group's display name for the group notices, only when the viewer
  #     may see that group, since a removed group can be one they can't;
  #   * names next to usernames in the composer's "hasn't been seen in a
  #     while" response.
  # The browser half (assets/javascripts/.../cardwell-message-names.js) puts
  # them into the three lines core builds with no hook: the screen-reader
  # heading on each notice, the activity stream line and that composer
  # message. The visible notice on a message is the theme's own component,
  # which reads the same field.
  #
  # Every field is additive: the handle stays where core expects it (links
  # are built from it), and each place falls back to the handle when there's
  # no name, so turning the part off restores core's lines exactly.
  module MessageNames
    USER_CODES = %w[invited_user removed_user user_left].freeze
    GROUP_CODES = %w[invited_group removed_group].freeze
    CODES = (USER_CODES + GROUP_CODES).freeze
    PRELOAD_KEY = :cardwell_action_code_who_names

    # enable_names is core's switch for showing names at all; with it off,
    # names stay off here too.
    def self.enabled?
      SiteSetting.cardwell_community_enabled && SiteSetting.cardwell_message_names_enabled &&
        SiteSetting.enable_names
    end

    # { [code, who] => display name } for the pairs that have one. Users by
    # name, groups by full name, both in one query each.
    def self.names_for(pairs, guardian)
      pairs = pairs.select { |code, who| CODES.include?(code) && who.present? }.uniq
      return {} if pairs.empty?

      user_handles = pairs.filter_map { |code, who| who.downcase if USER_CODES.include?(code) }
      group_handles = pairs.filter_map { |code, who| who.downcase if GROUP_CODES.include?(code) }

      users =
        if user_handles.empty?
          {}
        else
          User.where(username_lower: user_handles).pluck(:username_lower, :name).to_h
        end
      groups =
        if group_handles.empty?
          {}
        else
          Group
            .where("LOWER(name) IN (?)", group_handles)
            .select { |group| guardian.can_see_group?(group) }
            .to_h { |group| [group.name.downcase, group.full_name] }
        end

      pairs.each_with_object({}) do |(code, who), names|
        name = USER_CODES.include?(code) ? users[who.downcase] : groups[who.downcase]
        names[[code, who]] = name if name.present?
      end
    end

    # Runs once per TopicView: the handles on this page's notices, with their
    # names, stored by post id for PostSerializer. The handles come from the
    # custom fields TopicView has already loaded for the page (action_code_who
    # is one of its default fields); without them the serializer has no handle
    # either, so there's nothing to name.
    def self.preload(topic_view)
      return if !enabled?

      posts = topic_view.posts.select { |post| CODES.include?(post.action_code) }
      custom_fields = topic_view.post_custom_fields
      return if posts.empty? || custom_fields.blank?

      whos = posts.to_h { |post| [post.id, custom_fields.dig(post.id, "action_code_who")] }.compact
      pairs = posts.filter_map { |post| [post.action_code, whos[post.id]] if whos[post.id] }
      names = names_for(pairs, topic_view.guardian)

      topic_view.set_preloaded_post_data(
        PRELOAD_KEY,
        posts.to_h { |post| [post.id, names[[post.action_code, whos[post.id]]]] },
      )
    end

    # A post serialized outside a TopicView (/posts/:id.json, for one) and an
    # activity row look their one name up. New posts reach an open topic
    # through /t/:id/posts.json, which is a TopicView, so they're batched.
    def self.name_for(code, who, guardian, topic_view: nil, post_id: nil)
      return if !enabled? || !CODES.include?(code) || who.blank?

      preloaded = topic_view&.preloaded_post_data(PRELOAD_KEY)
      return preloaded[post_id] if preloaded&.key?(post_id)

      names_for([[code, who]], guardian)[[code, who]]
    end

    # Adds names next to the usernames core returns, in the same order. The
    # browser builds each link from the username, so that list is untouched.
    module ComposerMessagesControllerExtension
      def user_not_seen_in_a_while
        super
        return if !CardwellCommunity::MessageNames.enabled?

        body = JSON.parse(response.body)
        usernames = Array(body["usernames"])
        return if usernames.empty?

        names =
          User.where(username_lower: usernames.map(&:downcase)).pluck(:username_lower, :name).to_h
        body["names"] = usernames.map { |username| names[username.downcase].presence || username }
        self.response_body = body.to_json
      end
    end
  end
end
