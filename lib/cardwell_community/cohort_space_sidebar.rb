# frozen_string_literal: true

module CardwellCommunity
  # Part 12 (306-634). Each cohort and Thought Leaders segment has a private
  # category, its cohort space, readable by that cohort's group. Discourse never
  # adds a new category to anyone's sidebar: default_navigation_menu_categories
  # is applied when an account is created, and every member's account exists
  # before their space does (the sync creates the people and the group, then the
  # space is restricted to the group). So this part puts a space in its members'
  # sidebars, and keeps it there as the group changes:
  #
  # - when someone joins a group with access to a cohort space, it's added;
  # - when someone leaves and can no longer see it, it's removed;
  # - when a space is added to cardwell_cohort_space_categories, everyone
  #   already in its groups gets it.
  #
  # Only real groups count. Discourse's automatic groups (moderators, staff,
  # admins, trust levels) are skipped, so staff never get every space in their
  # sidebar just because moderators can read them all.
  module CohortSpaceSidebar
    def self.enabled?
      SiteSetting.cardwell_community_enabled && SiteSetting.cardwell_cohort_space_sidebar_enabled
    end

    def self.space_ids
      SiteSetting.cardwell_cohort_space_categories.to_s.split("|").map(&:to_i).select(&:positive?)
    end

    # Cohort spaces this group can read. Checked per group, not per user, so
    # joining an automatic group (moderators) never adds anything.
    def self.spaces_for(group, ids = space_ids)
      return [] if ids.empty? || group.nil? || group.automatic?

      CategoryGroup.where(group_id: group.id, category_id: ids).distinct.pluck(:category_id)
    end

    def self.member?(user)
      user.present? && user.human? && !user.staged?
    end

    def self.added_to_group(user, group)
      return unless enabled? && member?(user)

      add_links(user.id, spaces_for(group))
    end

    def self.removed_from_group(user, group)
      return unless enabled? && member?(user)

      ids = spaces_for(group)
      return if ids.empty?

      # The user's groups are read fresh, so a space still open to them through
      # another group stays in their sidebar. A user being deleted leaves their
      # groups too, and is gone by now: their links go with the account.
      fresh = User.find_by(id: user.id)
      return if fresh.nil?

      guardian = Guardian.new(fresh)
      gone = Category.where(id: ids).reject { |category| guardian.can_see_category?(category) }
      return if gone.empty?

      SidebarSectionLink.where(
        user_id: user.id,
        linkable_type: "Category",
        linkable_id: gone.map(&:id),
      ).delete_all
    end

    # Everyone already in a real group that can read one of these spaces gets
    # it: the first wave's accounts exist before their space does. Runs when an
    # id is added to the setting, so a space's permissions must be set before
    # its id goes in. The cohort spaces script also calls this after granting a
    # group access to an existing space.
    def self.add_for_members(category_ids)
      return unless enabled?

      ids = category_ids.map(&:to_i).select(&:positive?)
      return if ids.empty?

      rows =
        CategoryGroup
          .joins(:group)
          .joins("INNER JOIN group_users ON group_users.group_id = category_groups.group_id")
          .joins("INNER JOIN users ON users.id = group_users.user_id")
          .where(category_id: ids, groups: { automatic: false })
          .where("users.id > 0 AND NOT users.staged")
          .distinct
          .pluck("group_users.user_id", "category_groups.category_id")

      insert_links(rows)
    end

    def self.setting_changed(old_value, new_value)
      before = old_value.to_s.split("|").map(&:to_i)
      add_for_members(new_value.to_s.split("|").map(&:to_i) - before)
    end

    def self.add_links(user_id, category_ids)
      insert_links(category_ids.map { |category_id| [user_id, category_id] })
    end

    # One insert that skips links already there, so a join that races another
    # (an invite redemption fires the event twice) can't fail the request that
    # caused it. A member who removed a space from their sidebar keeps it
    # removed until they join a group with access again.
    def self.insert_links(pairs)
      return if pairs.empty?

      now = Time.zone.now
      SidebarSectionLink.insert_all(
        pairs.uniq.map do |user_id, category_id|
          {
            user_id: user_id,
            linkable_type: "Category",
            linkable_id: category_id,
            created_at: now,
            updated_at: now,
          }
        end,
        unique_by: %i[user_id linkable_type linkable_id],
      )
    end
  end
end
