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
    end

    module DirectoryItemsQueryExtension
      private

      # Runs on every directory request, after core's own exclusions.
      def exclude_usernames(items, usernames)
        CardwellCommunity::ProfileHiding.filter_directory(super, guardian)
      end
    end

    # Header and full-page search find people straight from User, not through
    # UserSearch. Core's search_user_search modifier gets that relation before
    # it runs, so a filter added there lands ahead of the LIMIT; but it gets no
    # guardian, so SearchExtension hands the searcher's over for the call.
    def self.with_search_guardian(guardian)
      previous = Thread.current[:cardwell_search_guardian]
      Thread.current[:cardwell_search_guardian] = guardian
      yield
    ensure
      Thread.current[:cardwell_search_guardian] = previous
    end

    def self.filter_search_users(users)
      guardian = Thread.current[:cardwell_search_guardian]
      guardian ? filter_users(users, guardian) : users
    end

    module SearchExtension
      private

      def user_search
        CardwellCommunity::ProfileHiding.with_search_guardian(@guardian) { super }
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
