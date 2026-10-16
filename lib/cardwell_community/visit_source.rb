# frozen_string_literal: true

module CardwellCommunity
  # Part 3 (306-498). PRD 3's week-two return counts new members who come back
  # in their second week without an email bringing them. Discourse keeps one
  # row per member per day (user_visits) and nothing about how they arrived, so
  # this part tags the links Cardwell sends and records where each visit came
  # from.
  #
  # - Tagging: links back to the community in the activity summary (digest) and
  #   notification emails get ?cw_src=digest or ?cw_src=notification, added in
  #   before_email_send, after Discourse has made every link absolute. Web push
  #   links get ?cw_src=push. The portal's invitations and reminders carry
  #   invite and reminder themselves (306-615).
  # - Recording: one row per member, day and source (decision 6, Jake, Oct 14).
  #   A page load with a known cw_src records that source, then redirects to the
  #   same address without it, so a link a member copies and shares doesn't
  #   carry the tag. A page load without one records "direct", the member coming
  #   on their own. The day is the server's UTC date, the same day user_visits
  #   uses, so the two join.
  #
  # Only full page loads reach the server. Moving around inside the app doesn't,
  # so a direct row means the member opened the community (a new tab, a
  # bookmark, the home screen app, a reload), not every page they read. A push
  # tap while the community is already open is routed inside the app by core's
  # service worker and isn't recorded (Kirk, Oct 16: server only, no new
  # JavaScript). Signed out, Discourse keeps the whole address, tag included,
  # through sign-in, and the visit is recorded when they land signed in.
  #
  # Off (the default until Cardwell decides to turn it on), emails and push go
  # out untagged and nothing is recorded. Rows already recorded stay.
  module VisitSource
    PARAM = "cw_src"

    # Decision 5 (Jake, Oct 14): one parameter, these values.
    TAGGED = %w[invite reminder digest notification push].freeze
    DIRECT = "direct"

    # Set on the redirect after a tagged arrival, so the clean address it lands
    # on isn't also counted as a direct visit. It expires rather than being
    # cleared, so several email links opened at once each land cleanly.
    LANDED_COOKIE = "cw_src_landed"

    # Email types (Email::Sender's second argument) that are notifications. The
    # account emails (sign-up, password, email login and the like) carry tokens
    # and aren't Cardwell bringing anyone back, so they're left alone.
    NOTIFICATION_EMAILS = %w[
      user_replied
      user_quoted
      user_linked
      user_mentioned
      group_mentioned
      user_posted
      user_private_message
      user_invited_to_private_message
      user_invited_to_topic
      user_watching_first_post
      mailing_list
    ].freeze

    # Links in an email that stay untagged: unsubscribe links (keyed, not a page
    # of the app) and files.
    UNTAGGED_PATHS = %r{\A/(?:email/|unsubscribe|uploads/|secure-uploads/|secure-media-uploads/)}

    # Page loads that aren't a member visiting: signing in or out, account and
    # email links, invitations, files, and the offline page the service worker
    # fetches in the background when it installs or updates.
    NOT_A_VISIT_PATHS =
      %r{\A/(?:session/|auth/|login|signup|email/|unsubscribe|invites/|u/activate-account|u/password-reset|u/confirm-|user-api-key|uploads/|secure-uploads/|secure-media-uploads/|offline)}

    # A URL in a plain-text email. Markdown wraps links in parentheses and angle
    # brackets, so those end it.
    TEXT_URL = %r{https?://[^\s<>()"'\[\]]+}

    def self.enabled?
      SiteSetting.cardwell_community_enabled && SiteSetting.cardwell_visit_source_enabled
    end

    def self.email_source(email_type)
      type = email_type.to_s
      return "digest" if type == "digest"
      "notification" if NOTIFICATION_EMAILS.include?(type)
    end

    # Adds the tag to a URL or path, before any #fragment. A URL that already
    # has one keeps it.
    def self.append(url, source)
      address, mark, fragment = url.partition("#")
      path, _question, query = address.partition("?")
      pairs = query.split("&")
      return url if pairs.any? { |pair| pair.start_with?("#{PARAM}=") }

      tagged = "#{path}?#{(pairs + ["#{PARAM}=#{source}"]).join("&")}"
      "#{tagged}#{mark}#{fragment}"
    end

    # The local path of a link to this community, or nil for anywhere else.
    def self.local_path(url)
      uri = URI.parse(url)
      base = URI.parse(Discourse.base_url)
      return if %w[http https].exclude?(uri.scheme) || !uri.host&.casecmp?(base.host)

      path = uri.path.to_s
      base_path = Discourse.base_path
      return if base_path.present? && !path.start_with?(base_path)

      path.delete_prefix(base_path).presence || "/"
    rescue URI::Error
      nil
    end

    def self.tag_url(url, source)
      path = local_path(url)
      return url if path.nil? || path.match?(UNTAGGED_PATHS)

      append(url, source)
    end

    def self.tag_html(html, source)
      doc = Nokogiri::HTML5.parse(html)
      doc.css("a[href]").each { |link| link["href"] = tag_url(link["href"], source) }
      doc.to_s
    end

    def self.tag_text(text, source)
      text.gsub(TEXT_URL) do |match|
        # A sentence can end right after a link.
        url = match.sub(/[.,;:!?]+\z/, "")
        "#{tag_url(url, source)}#{match.delete_prefix(url)}"
      end
    end

    # Called from before_email_send, after Discourse has finished the HTML.
    def self.tag_email(message, email_type)
      return unless enabled?

      source = email_source(email_type)
      return if source.nil?

      if (part = message.html_part)
        part.body = tag_html(part.decoded, source)
      end
      if (part = message.text_part)
        part.body = tag_text(part.decoded, source)
      end
    end

    # The web push payload's post_url is a path; the browser opens it on this
    # site.
    def self.tag_push_payload(payload)
      return payload if !enabled? || payload[:post_url].blank?

      payload.merge(post_url: append(payload[:post_url], "push"))
    end

    # The address to send a tagged arrival on to. Always a path on this site:
    # leading slashes collapse to one, so a request for //elsewhere can't turn
    # the redirect into a link off the site.
    def self.without_param(fullpath)
      path, _question, query = fullpath.partition("?")
      path = "/#{path.sub(%r{\A[/\\]+}, "")}"
      # Compared decoded, as Rails reads it, so an encoded cw%5Fsrc can't loop.
      rest =
        query.split("&").reject { |pair| Rack::Utils.unescape(pair.split("=", 2).first) == PARAM }
      rest.empty? ? path : "#{path}?#{rest.join("&")}"
    end

    # A page the member opened: not an account or background path, and not a
    # fetch the browser says isn't a top-level page (a service worker's fetch, an
    # iframe). Browsers that don't send Sec-Fetch-Dest are taken at their word.
    def self.visit?(request)
      dest = request.headers["Sec-Fetch-Dest"]
      return false if dest.present? && dest != "document"

      !request.path.delete_prefix(Discourse.base_path).match?(NOT_A_VISIT_PATHS)
    end

    # A page opened from a link inside the community (a topic opened in a new
    # tab) is the same visit going on, not the member arriving on their own.
    def self.from_inside?(request)
      request.headers["Sec-Fetch-Site"] == "same-origin"
    end

    def self.record(user, source)
      return if Discourse.readonly_mode?

      DB.exec(<<~SQL, user_id: user.id, visited_at: Time.zone.now.to_date, source: source)
        INSERT INTO cardwell_visit_sources (user_id, visited_at, source, created_at)
        VALUES (:user_id, :visited_at, :source, NOW())
        ON CONFLICT (user_id, visited_at, source) DO NOTHING
      SQL
    rescue StandardError => e
      # A missed row never costs the member their page.
      Discourse.warn_exception(e, message: "Cardwell community: couldn't record a visit source")
    end

    module PushNotificationPusherExtension
      def push(user, payload)
        super(user, CardwellCommunity::VisitSource.tag_push_payload(payload))
      end
    end

    # Included in ApplicationController, so every controller that can serve the
    # app's first page load gets both callbacks.
    module ControllerExtension
      extend ActiveSupport::Concern

      included do
        before_action :cardwell_visit_source_arrival
        after_action :cardwell_visit_source_direct
      end

      private

      # The cheap checks come first and the session lookup last, since these
      # run on every GET a controller serves, images and stylesheets included.
      def cardwell_visit_source_arrival
        return if !CardwellCommunity::VisitSource.enabled? || !spa_boot_request?

        source = request.query_parameters[CardwellCommunity::VisitSource::PARAM]
        return if CardwellCommunity::VisitSource::TAGGED.exclude?(source)
        return if !CardwellCommunity::VisitSource.visit?(request) || !current_user

        CardwellCommunity::VisitSource.record(current_user, source)
        cookies[CardwellCommunity::VisitSource::LANDED_COOKIE] = {
          value: "1",
          max_age: 60,
          httponly: true,
        }
        redirect_to CardwellCommunity::VisitSource.without_param(request.fullpath)
      end

      def cardwell_visit_source_direct
        return if !CardwellCommunity::VisitSource.enabled? || !spa_boot_request?
        return if response.status != 200 || response.media_type != "text/html"
        return if !CardwellCommunity::VisitSource.visit?(request)
        return if CardwellCommunity::VisitSource.from_inside?(request)
        return if cookies[CardwellCommunity::VisitSource::LANDED_COOKIE] || !current_user

        CardwellCommunity::VisitSource.record(current_user, CardwellCommunity::VisitSource::DIRECT)
      end
    end
  end
end
