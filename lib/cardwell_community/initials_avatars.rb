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
  # after the first view an avatar never reaches the web workers, as today's
  # don't. Core's own route there takes three segments after the prefix
  # (username, size, version), so this four-segment one can't collide with it.
  #
  # Avatars load without a session (email clients fetch them signed out), so
  # the route answers anyone. A username with no account gets initials from
  # the username itself (john.smith → JS): with the sync's firstname.lastname
  # usernames, guessing a username shows the same image whether or not the
  # person is a member. Only a member with no name on file shows differently
  # (one letter, core's rule; Kirk, Oct 15).
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

    # How long browsers and nginx keep an avatar: the 1-day rule
    # from decision 9 (Jake, Oct 14). A renamed username is a new URL, so it
    # shows at once; a name edit that keeps the username shows within a day.
    MAX_AGE = 1.day

    def self.enabled?
      SiteSetting.cardwell_community_enabled && SiteSetting.cardwell_initials_avatars_enabled
    end

    def self.template(username)
      color = User.letter_avatar_color(User.normalize_username(username))
      "#{Discourse.base_path}#{PATH_PREFIX}/#{UrlHelper.encode_component(username)}/#{color}/{size}.png"
    end

    def self.initials_for_username(username)
      user = User.find_by(username_lower: User.normalize_username(username))
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

    # The route answers anyone, so nothing in the URL may make the server draw
    # and keep an open-ended set of files. The color comes from the username,
    # never the URL, and the size is rounded up to one of the avatar_sizes
    # browsers ask for (getRawAvatarSize picks from the same list).
    def self.image_for(username, size)
      initials = initials_for_username(username)
      color = User.letter_avatar_color(User.normalize_username(username))
      size = allowed_size(size)

      DistributedMutex.synchronize("cardwell_initials_avatar_#{initials}_#{color}") do
        filename = cached_path(initials, color, size)
        next filename if File.exist?(filename)

        fullsize = cached_path(initials, color, FULLSIZE)
        draw(initials, color, fullsize) if !File.exist?(fullsize)
        OptimizedImage.resize(fullsize, filename, size, size) if size != FULLSIZE
        filename
      end
    end

    def self.allowed_size(size)
      sizes = Discourse.avatar_sizes.to_a.sort
      sizes.find { |allowed| allowed >= size } || sizes.last
    end

    def self.cache_dir
      "tmp/cardwell_initials_avatars/#{VERSION}"
    end

    # Initials can be any letters, so the directory is named by their hex
    # bytes rather than the letters themselves.
    def self.cached_path(initials, color, size)
      dir = File.join(cache_dir, initials.unpack1("H*"), color)
      FileUtils.mkdir_p(dir)
      File.expand_path(File.join(dir, "#{size}.png"))
    end

    # If a discourse-fonts update moves the file, Helvetica keeps avatars
    # drawing rather than failing.
    def self.font
      path = File.join(DiscourseFonts.path_for_fonts, INTER_FILE)
      File.exist?(path) ? path : "Helvetica"
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
