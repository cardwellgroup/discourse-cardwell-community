# frozen_string_literal: true

module CardwellCommunity
  # Serves part 10's initials avatars (see InitialsAvatars). Like core's own
  # letter avatar route, it answers without a session: email clients and
  # signed-out pages fetch avatars with no cookies.
  #
  # It serves whether or not the part is on. Turning it off stops new pages
  # from linking here, but quotes cooked into posts keep the URL they were
  # cooked with, and those images must keep loading, so no requires_plugin.
  class InitialsAvatarsController < ::ApplicationController
    skip_before_action :preload_json,
                       :redirect_to_login_if_required,
                       :redirect_to_profile_if_required,
                       :check_xhr,
                       :verify_authenticity_token

    before_action :apply_cdn_headers

    def show
      is_asset_path
      no_cookies

      username = params.require(:username).to_s
      size = params.require(:size).to_i

      # Before the hijack, so an over-limit request gets the usual 429.
      if InitialsAvatars.find_member(username).nil?
        RateLimiter.new(
          nil,
          "cardwell_initials_avatar_#{request.remote_ip}",
          InitialsAvatars::STRANGER_DRAWS_PER_MINUTE,
          1.minute,
        ).performed!
      end

      hijack do
        InitialsAvatars.with_image(username, size) do |image|
          response.headers["Last-Modified"] = File.ctime(image).httpdate
          response.headers["X-Accel-Expires"] = InitialsAvatars::NGINX_MAX_AGE.to_i.to_s
          expires_in InitialsAvatars::BROWSER_MAX_AGE, public: true
          # Read now: a stranger's tile is deleted when the block returns.
          send_data File.binread(image), type: "image/png", disposition: "inline"
        end
      end
    end
  end
end
