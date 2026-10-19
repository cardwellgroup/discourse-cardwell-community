# frozen_string_literal: true

module CardwellCommunity
  # Part 7 (306-528). The theme's directory used to check moderation state in
  # the browser: members loaded card details for everyone to drop suspended
  # people, about a second per 50 members, and staff paged through three admin
  # user lists (active, suspended, silenced). This part answers both from the
  # directory request instead.
  #
  # - Members: suspended people are left out of /directory_items, so the list
  #   and its total are right as served. Core keeps suspended members in the
  #   directory.
  # - Staff: each directory row carries `cardwell_staff` (suspended until,
  #   silenced until, joined, last seen, days visited). Core drops silenced
  #   members from the directory when it refreshes it, so staff read those from
  #   /cardwell/directory/silenced.json, in the directory's own row shape.
  #
  # Paused, revoked and departed members are part 2's (ProfileHiding), which
  # filters the same query for members.
  module DirectoryChecks
    def self.on?
      SiteSetting.cardwell_community_enabled && SiteSetting.cardwell_directory_checks_enabled
    end

    def self.suspended_user_ids
      User.where("suspended_till > ?", Time.zone.now).select(:id)
    end

    def self.filter_directory(items, guardian)
      return items if !on? || guardian.is_staff?

      items.where.not(user_id: suspended_user_ids)
    end

    # What the staff view shows for each person.
    def self.staff_fields(user, user_stat)
      {
        suspended_till: user.suspended_till,
        silenced_till: user.silenced_till,
        created_at: user.created_at,
        last_seen_at: user.last_seen_at,
        days_visited: user_stat&.days_visited,
      }
    end

    # The accounts core leaves out of the directory for being silenced: any
    # silence end date, past or future, since core's refresh keeps a row only
    # while it's empty. Real, activated accounts, as core lists.
    def self.silenced_users(group: nil)
      users =
        User
          .where(active: true, staged: false)
          .where("users.id > 0")
          .where.not(silenced_till: nil)
          .where(
            "NOT EXISTS (SELECT 1 FROM directory_items di WHERE di.user_id = users.id AND di.period_type = ?)",
            DirectoryItem.period_types[:all],
          )
      users = users.where(id: GroupUser.where(group_id: group.id).select(:user_id)) if group
      users.includes(:user_custom_fields, :primary_group, :user_stat).order(:username_lower)
    end

    module DirectoryItemsQueryExtension
      private

      # Runs on every directory request, after core's own exclusions.
      def exclude_usernames(items, usernames)
        CardwellCommunity::DirectoryChecks.filter_directory(super, guardian)
      end
    end
  end
end
