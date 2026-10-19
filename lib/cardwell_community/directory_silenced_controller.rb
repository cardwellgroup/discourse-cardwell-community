# frozen_string_literal: true

module CardwellCommunity
  # Part 7 (see DirectoryChecks): the silenced members core leaves out of the
  # directory, for staff, in the directory's own row shape so the theme can add
  # them to its list. Takes the directory's `user_field_ids` and `group`.
  class DirectorySilencedController < ::ApplicationController
    requires_plugin ::CardwellCommunity::PLUGIN_NAME

    before_action :ensure_staff

    # Far above how many silenced members the community has; past it, the rest
    # are left out without a note.
    MAX_ROWS = 1000

    def index
      raise Discourse::NotFound if !DirectoryChecks.on?

      group = nil
      if params[:group].present?
        group = Group.find_by(name: params[:group])
        raise Discourse::InvalidParameters.new(:group) if group.blank?
        guardian.ensure_can_see_group_and_members!(group)
      end

      field_map = user_field_map
      serializer_opts = { scope: guardian, root: false, user_custom_field_map: field_map }
      serializer_opts[:searchable_fields] = UserField.where(searchable: true) if field_map.present?

      rows =
        DirectoryChecks
          .silenced_users(group:)
          .limit(MAX_ROWS)
          .map do |user|
            {
              id: user.id,
              user: DirectoryItemSerializer::UserSerializer.new(user, **serializer_opts).as_json,
              days_visited: user.user_stat&.days_visited,
              cardwell_staff: DirectoryChecks.staff_fields(user, user.user_stat),
            }
          end

      render json: { directory_items: rows }
    end

    private

    # As core's directory builds it; staff may ask for every field.
    def user_field_map
      ids = params[:user_field_ids].to_s.split("|").map(&:to_i) & UserField.pluck(:id)
      ids.index_by { |id| "#{User::USER_FIELD_PREFIX}#{id}" }
    end
  end
end
