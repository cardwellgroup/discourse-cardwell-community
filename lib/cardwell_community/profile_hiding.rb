# frozen_string_literal: true

module CardwellCommunity
  # Part 2 (306-498). A paused or revoked member stays in Discourse with their
  # posts up, but other members shouldn't find them: no profile, no directory
  # row, no @mention suggestion. Cardwell Auth's sync (COL-388) keeps everyone
  # who's active in one group; this part hides anyone outside it (PRD 4,
  # decisions 1 to 4, Jake, Oct 14).
  #
  # - Profiles: Guardian#can_see_profile? says no. Core then answers the
  #   profile and the user card with name, username and photo only
  #   (HiddenProfileSerializer, profile_hidden: true), leaves them out of the
  #   batch card request, and refuses their activity, summary and badges. The
  #   theme shows that stub as "Inactive member".
  # - Directory: their rows are left out of /directory_items for members, the
  #   list the theme's directory and landing page read.
  # - Search: user search (the @mention and message pickers, the directory's
  #   search box) and the people in header and full-page search skip them.
  # - Groups (306-636): group member lists leave them out, and each group's
  #   member count drops them, so a state group's "12 members" matches the 11
  #   it lists.
  # - Badges (306-636): a badge's list of who has it leaves them out, its
  #   grant count drops them, and its RSS feed of grantees is refused.
  #
  # Never hidden: anyone viewing their own profile, staff viewing anyone, and
  # admins, moderators, Discourse's own bots and the exempt groups (the
  # Cardwell team, decision 2) as the people being viewed.
  #
  # With no active-member group set, nobody is hidden (decision 1). That's how
  # it ships: the setting is filled once the sync fills the group.
  #
  # A member who left is anonymized under PRD 4's proposal (pending Cassie),
  # so they're outside the group too, and the theme shows "Former member" for
  # an anonymized author before a card is ever asked for.
  module ProfileHiding
    def self.group_ids(value)
      value.to_s.split("|").map(&:to_i).select(&:positive?)
    end

    def self.active_group_ids
      group_ids(SiteSetting.cardwell_active_member_groups)
    end

    def self.exempt_group_ids
      group_ids(SiteSetting.cardwell_profile_hiding_exempt_groups)
    end

    def self.on?
      SiteSetting.cardwell_community_enabled && active_group_ids.present?
    end

    # Viewers who see everyone: staff.
    def self.sees_everyone?(guardian)
      guardian.is_staff?
    end

    # Whether the guardian's user may see this person's profile.
    def self.visible?(user, guardian)
      return true if !on? || user.nil? || sees_everyone?(guardian)
      return true if guardian.user&.id == user.id
      return true if user.id <= 0 || user.admin? || user.moderator?

      GroupUser.exists?(user_id: user.id, group_id: active_group_ids + exempt_group_ids)
    end

    # The same rule as SQL over users, for lists: bots, admins, moderators,
    # the active and exempt groups, and the viewer themself.
    def self.visible_users_sql(guardian)
      DB.sql_fragment(
        <<~SQL,
          users.id <= 0 OR users.admin OR users.moderator OR users.id = :viewer_id
          OR users.id IN (SELECT user_id FROM group_users WHERE group_id IN (:group_ids))
        SQL
        viewer_id: guardian.user&.id || 0,
        group_ids: active_group_ids + exempt_group_ids,
      )
    end

    def self.filter_users(users, guardian)
      return users if !on? || sees_everyone?(guardian)

      users.where(visible_users_sql(guardian))
    end

    def self.filter_directory(items, guardian)
      return items if !on? || sees_everyone?(guardian)

      items.where(user_id: User.where(visible_users_sql(guardian)).select(:id))
    end

    def self.filter_user_badges(user_badges, guardian)
      return user_badges if !on? || sees_everyone?(guardian)

      user_badges.where(user_id: User.where(visible_users_sql(guardian)).select(:id))
    end

    # Hidden members per group, { group_id => count }, for every group at once.
    # One aggregate per request however many groups a page shows;
    # GuardianExtension keeps the answer. BasicGroupSerializer is embedded
    # wherever a group appears (profiles, message participants, search,
    # invites, chat), so this runs on most member page views. That is cheap at
    # the community's size; revisit it if group_users grows into the hundreds
    # of thousands. Hidden people always have a positive id (bots are never
    # hidden), the same people core's user_count tally counts, so subtracting
    # this from user_count gives exactly the members a viewer is shown.
    def self.hidden_group_member_counts(guardian)
      GroupUser.joins(:user).where("NOT (#{visible_users_sql(guardian)})").group(:group_id).count
    end

    # Hidden grantees per badge, { badge_id => rows }. badges.grant_count counts
    # user_badges rows (a badge granted twice counts twice), and the grantee
    # list returns those same rows, so this counts rows too. BadgeSerializer is
    # embedded in every user badge (user cards, summaries, badge listings, post
    # headers), so like the group aggregate this runs once on most member page
    # views; cheap at the community's size, and worth revisiting on the same
    # terms if user_badges grows into the hundreds of thousands.
    def self.hidden_badge_grant_counts(guardian)
      UserBadge.joins(:user).where("NOT (#{visible_users_sql(guardian)})").group(:badge_id).count
    end

    # A count with the viewer's hidden people taken out. Unchanged with hiding
    # off, for staff, and where a serializer has no guardian at all.
    def self.visible_count(count, guardian, hidden_counts_method, id)
      return count if count.nil? || guardian.nil? || !on? || sees_everyone?(guardian)

      [count - guardian.public_send(hidden_counts_method).fetch(id, 0), 0].max
    end

    module GuardianExtension
      # Lists ask once per person (group members, batch cards), so each
      # person's answer is kept for the life of this guardian, one request.
      def can_see_profile?(user)
        return false if !super

        @cardwell_profile_visible ||= {}
        @cardwell_profile_visible.fetch(user.id) do
          @cardwell_profile_visible[user.id] = CardwellCommunity::ProfileHiding.visible?(user, self)
        end
      end

      # The groups and badges pages serialize every row with this one guardian.
      def cardwell_hidden_group_member_counts
        @cardwell_hidden_group_member_counts ||=
          CardwellCommunity::ProfileHiding.hidden_group_member_counts(self)
      end

      def cardwell_hidden_badge_grant_counts
        @cardwell_hidden_badge_grant_counts ||=
          CardwellCommunity::ProfileHiding.hidden_badge_grant_counts(self)
      end
    end

    module DirectoryItemsQueryExtension
      private

      # Runs on every directory request, after core's own exclusions.
      def exclude_usernames(items, usernames)
        CardwellCommunity::ProfileHiding.filter_directory(super, guardian)
      end
    end

    # Two lists are built where no guardian reaches. Header and full-page
    # search find people straight from User, not through UserSearch: core's
    # search_user_search modifier gets that relation ahead of its LIMIT, but
    # no guardian. Group member lists come from Group#listed_users, a model
    # method. So the code that has the guardian (SearchExtension,
    # GroupsControllerExtension) hands it over for the length of the call, and
    # the filter reads it back. Outside such a call it is nil and nothing is
    # filtered. One other core caller of listed_users exists: the MCP server's
    # ListGroupMembers tool (lib/discourse_mcp/tools/groups.rb), which also
    # returns the raw user_count. It is NOT filtered, so mcp_server_enabled
    # must stay off while hiding is on (it is off by default; README, core
    # hooks).
    def self.with_request_guardian(guardian)
      previous = Thread.current[:cardwell_request_guardian]
      Thread.current[:cardwell_request_guardian] = guardian
      yield
    ensure
      Thread.current[:cardwell_request_guardian] = previous
    end

    def self.filter_request_users(users)
      guardian = Thread.current[:cardwell_request_guardian]
      guardian ? filter_users(users, guardian) : users
    end

    module SearchExtension
      private

      def user_search
        CardwellCommunity::ProfileHiding.with_request_guardian(@guardian) { super }
      end
    end

    # GET /groups/:name/members. The list, the owners and meta.total all come
    # from group.listed_users, so filtering that one relation keeps the three
    # in step. The requesters branch reads group.requesters and is reached only
    # by the group's editors, so it is left alone.
    module GroupsControllerExtension
      def members
        CardwellCommunity::ProfileHiding.with_request_guardian(guardian) { super }
      end
    end

    module GroupExtension
      def listed_users
        CardwellCommunity::ProfileHiding.filter_request_users(super)
      end
    end

    # user_count is the groups.user_count column, which counts hidden members.
    # Every serializer that shows a group inherits it from here
    # (GroupShowSerializer, the groups list, chat's ChatableGroupSerializer).
    # Webhook payloads serialize as the system user, which is staff, so their
    # count is the full one. /groups.json?order=user_count still sorts by the
    # column, so with hidden members the order can disagree with the counts.
    module BasicGroupSerializerExtension
      def user_count
        CardwellCommunity::ProfileHiding.visible_count(
          super,
          scope,
          :cardwell_hidden_group_member_counts,
          object.id,
        )
      end
    end

    # GET /user_badges.json, every listing of who has which badge (by badge,
    # badge name, badge ids or type, or all listable badges). With a username
    # the controller already refuses a hidden profile first.
    module UserBadgesControllerExtension
      private

      def scoped_user_badges
        CardwellCommunity::ProfileHiding.filter_user_badges(super, guardian)
      end
    end

    # grant_count is the badges.grant_count column, which counts hidden
    # members. The badge page's "load more" runs until it has listed
    # grant_count rows (badges/show.js canLoadMore), so leaving it raw while
    # the list is filtered keeps the spinner up and the footer hidden for good.
    module BadgeSerializerExtension
      def grant_count
        CardwellCommunity::ProfileHiding.visible_count(
          super,
          scope,
          :cardwell_hidden_badge_grant_counts,
          object.id,
        )
      end
    end

    # /badges/:id.rss renders @badge.user_badges straight from the association
    # in a core view (badges/show.rss.erb), past every filter above. Rather
    # than override a core template, the feed is refused to anyone whose view
    # is filtered; staff still get it. The community needs a login, so no
    # feed reader was using it.
    module BadgesControllerExtension
      def show
        if request.format.rss? && CardwellCommunity::ProfileHiding.on? &&
             !CardwellCommunity::ProfileHiding.sees_everyone?(guardian)
          raise Discourse::NotFound
        end

        super
      end
    end

    module UserSearchExtension
      # Every path in UserSearch#search_ids starts here, so hidden members drop
      # out before the result limit.
      def scoped_users
        CardwellCommunity::ProfileHiding.filter_users(super, @guardian)
      end
    end
  end
end
