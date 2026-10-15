# frozen_string_literal: true

module CardwellCommunity
  # Part 10 (306-587). Someone with no photo gets a letter avatar, and core's
  # letter is the first letter of the username. The community's usernames come
  # from the Cardwell Auth sync, so a member would show one letter of whatever
  # username they were given. This part draws two initials from the name
  # instead ("Dana Whitfield" → DW), in the same per-person color core gives
  # them today.
  #
  # Core hands out every letter avatar through User.system_avatar_template, so
  # posts, lists, the header, notifications, emails, the directory, profiles,
  # user cards and the landing page all switch at once. Off, the method is
  # core's again and avatars go back to today's letters, with no setting to
  # change by hand.
  #
  # Today's letters aren't drawn on this server: the default
  # external_system_avatars_url relays Discourse's own image service
  # (/letter_avatar_proxy → avatars.discourse-cdn.com). This part draws with
  # the server's ImageMagick instead, in Inter, at the same letter height.
  #
  # The URL sits under /letter_avatar/ on purpose. The container's nginx
  # caches that prefix (proxy_cache in discourse_docker's nginx template), so
  # while nginx holds an avatar it never reaches the web workers, as today's
  # letters don't. Core's own route there takes three segments after the
  # prefix (username, size, version), so this four-segment one can't collide
  # with it.
  #
  # Avatars load without a session (email clients fetch them signed out), so
  # the route answers anyone. A username with no account gets initials from
  # the username itself (john.smith → JS), so when a member's name matches the
  # firstname.lastname username the sync gives them, a guessed username shows
  # the same image whether or not the person is a member. A member whose name
  # doesn't match (bob.smith named Robert Smith, or no name on file, which
  # shows core's one letter; Kirk, Oct 15) shows differently.
  #
  # Strangers' usernames can be anything, so their tiles are never kept: each
  # is drawn into a temporary directory, sent and thrown away, and the
  # controller rate-limits those draws per IP. Only members' tiles are kept on
  # disk, a set bounded by the members, their colors and the avatar sizes.
  module InitialsAvatars
    PATH_PREFIX = "/letter_avatar/cardwell"

    # Bump when the drawing changes, so files drawn the old way aren't reused.
    VERSION = 1

    # Drawn once at this size and scaled down, like core's LetterAvatar.
    FULLSIZE = 360

    # A single letter matches today's: a "D" from Discourse's image service
    # stands 157 px tall on a 360 px tile, which Inter reaches at 215 points.
    POINTSIZE = 215

    # Every pair is one size, so two-letter avatars look alike from person to
    # person (Kirk, Oct 15). It's sized for the widest pair: "WW" at 150 points
    # is 289 x 110 px, and its corners sit 155 px from the center, inside the
    # 180 px circle the theme crops avatars to.
    PAIR_POINTSIZE = 150
    FILL = "#FFFFFFCC"

    # Inter, the community's UI font (Kirk, Oct 15), from the discourse-fonts
    # gem core already ships; ImageMagick reads the woff2 through FreeType.
    INTER_FILE = "InterVariable.woff2"

    # Credentials come after a comma ("Jane Doe, CPA") and suffixes come last
    # ("John Smith Jr."); neither belongs in initials (Kirk, Oct 15).
    SUFFIXES = %w[jr sr ii iii iv v].freeze

    # Decision 9 (Jake, Oct 14): a name edit that keeps the username shows
    # within a day. nginx and browsers each keep an avatar for half of that:
    # a browser that fetches from nginx just before nginx's copy expires keeps
    # it for another 12 hours, so the worst case is 24. nginx reads its own
    # time from X-Accel-Expires, which outranks Cache-Control and isn't passed
    # on to browsers. A renamed username is a new URL, so it shows at once.
    NGINX_MAX_AGE = 12.hours
    BROWSER_MAX_AGE = 12.hours

    # Draws for usernames with no account, per IP per minute. A member's
    # browser rarely makes any: templates are only handed out for accounts.
    STRANGER_DRAWS_PER_MINUTE = 30

    def self.enabled?
      SiteSetting.cardwell_community_enabled && SiteSetting.cardwell_initials_avatars_enabled
    end

    def self.template(username)
      color = User.letter_avatar_color(User.normalize_username(username))
      "#{Discourse.base_path}#{PATH_PREFIX}/#{UrlHelper.encode_component(username)}/#{color}/{size}.png"
    end

    def self.find_member(username)
      User.find_by(username_lower: User.normalize_username(username))
    end

    def self.initials_for_username(username, user = find_member(username))
      return initials_from_username_parts(username) if user.nil?

      initials_from_name(user.name) || first_letter(user.username)
    end

    # First letter of the first and last words; one word gives one letter.
    # Returns nil when the name has no letters at all.
    def self.initials_from_name(name)
      words = name.to_s.unicode_normalize(:nfc).split(",").first.to_s.split
      words.pop while words.size > 1 && SUFFIXES.include?(words.last.downcase.delete("."))
      letters = words.filter_map { |word| word[/\p{L}/] }
      return if letters.empty?

      (letters.size > 1 ? letters.first + letters.last : letters.first).upcase
    end

    def self.initials_from_username_parts(username)
      letters =
        username.to_s.unicode_normalize(:nfc).split(/[._-]+/).filter_map { |part| part[/\p{L}/] }
      return first_letter(username) if letters.empty?

      (letters.size > 1 ? letters.first + letters.last : letters.first).upcase
    end

    # Core's rule: the first character of the username, upper-cased. Only a
    # letter or digit is drawn: ImageMagick reads text starting with @ as a
    # file name and % as a format escape, and the route takes any username.
    def self.first_letter(username)
      letter = User.normalize_username(username).to_s.grapheme_clusters.first.to_s.upcase
      letter.match?(/\A[\p{L}\p{N}]\p{M}*\z/) ? letter : "?"
    end

    # Yields the path of the tile for this username at this size. The color
    # comes from the username, never the URL, and the size is rounded up to
    # one of the avatar_sizes browsers ask for (getRawAvatarSize picks from
    # the same list). A member's tile is kept and reused; a stranger's is
    # drawn into a temporary directory that's removed after the block.
    def self.with_image(username, size)
      user = find_member(username)
      initials = initials_for_username(username, user)
      color = User.letter_avatar_color(User.normalize_username(username))
      size = allowed_size(size)

      if user.nil?
        Dir.mktmpdir("cardwell-initials-") do |dir|
          yield render(initials, color, size, ->(s) { File.join(dir, "#{s}.png") })
        end
      else
        image =
          DistributedMutex.synchronize("cardwell_initials_avatar_#{initials}_#{color}") do
            render(initials, color, size, ->(s) { cached_path(initials, color, s) })
          end
        yield image
      end
    end

    # Draws the full-size tile if it isn't there, then the requested size.
    def self.render(initials, color, size, path_for)
      filename = path_for.call(size)
      return filename if File.exist?(filename)

      fullsize = path_for.call(FULLSIZE)
      draw(initials, color, fullsize) if !File.exist?(fullsize)
      OptimizedImage.resize(fullsize, filename, size, size) if size != FULLSIZE
      raise "#{PLUGIN_NAME}: could not draw the #{size}px initials avatar" if !File.exist?(filename)

      filename
    end

    def self.allowed_size(size)
      sizes = Discourse.avatar_sizes.to_a.sort
      sizes.find { |allowed| allowed >= size } || sizes.last
    end

    def self.cache_root
      "tmp/cardwell_initials_avatars"
    end

    # Named by version and font, so tiles drawn in the fallback font are never
    # served as Inter once the file is back.
    def self.cache_dir
      File.join(cache_root, VERSION.to_s, File.basename(font).sub(/\..*\z/, "").downcase)
    end

    # Like core's LetterAvatar.cleanup_old: run at boot, so a VERSION bump
    # doesn't leave the old tiles on disk.
    def self.cleanup_old
      return if !Dir.exist?(cache_root)

      Dir
        .children(cache_root)
        .each { |entry| FileUtils.rm_rf(File.join(cache_root, entry)) if entry != VERSION.to_s }
    rescue StandardError => e
      Rails.logger.warn("#{PLUGIN_NAME}: could not clear old initials avatars: #{e.message}")
    end

    # Initials can be any letters, so the directory is named by their hex
    # bytes rather than the letters themselves.
    def self.cached_path(initials, color, size)
      dir = File.join(cache_dir, initials.unpack1("H*"), color)
      FileUtils.mkdir_p(dir)
      File.expand_path(File.join(dir, "#{size}.png"))
    end

    # If a discourse-fonts update moves the file, Helvetica keeps avatars
    # drawing rather than failing (the container's ImageMagick resolves it;
    # checked on the droplet Oct 15). Inter has no CJK or Arabic glyphs, so
    # names in those scripts would draw as boxes either way.
    def self.font
      path = File.join(DiscourseFonts.path_for_fonts, INTER_FILE)
      return path if File.exist?(path)

      Rails.logger.warn("#{PLUGIN_NAME}: #{INTER_FILE} not found, drawing initials in Helvetica")
      "Helvetica"
    end

    def self.draw(initials, color, filename)
      pointsize = initials.grapheme_clusters.size > 1 ? PAIR_POINTSIZE : POINTSIZE

      ImageProcessing::OutputFile.write(filename) do |temporary_path|
        ImageMagick.magick(
          "-size",
          "#{FULLSIZE}x#{FULLSIZE}",
          "xc:##{color}",
          "-pointsize",
          pointsize.to_s,
          "-fill",
          FILL,
          "-font",
          font,
          "-gravity",
          "Center",
          # gravity Center puts Inter's capitals within a pixel of the middle
          # of the tile (measured for D, DW, MW and PR), so no offset.
          "-annotate",
          "+0+0",
          initials,
          "-depth",
          "8",
          temporary_path,
          operation: :cardwell_initials_avatar_render,
          write: [temporary_path],
        )
      end
    end

    module UserExtension
      def system_avatar_template(username)
        return super if username.blank? || !CardwellCommunity::InitialsAvatars.enabled?

        CardwellCommunity::InitialsAvatars.template(username)
      end
    end
  end
end
