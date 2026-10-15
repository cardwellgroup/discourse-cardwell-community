# frozen_string_literal: true

module CardwellCommunity
  # Part 11 (306-609). The 306 Community theme ships every Lucide icon in its
  # icons-sprite, each named with the lucide- prefix, and every category,
  # sidebar link, badge and group flair on the site uses one. Discourse's icon
  # pickers (category icon, sidebar links, group flair, badges) still offer
  # core's Font Awesome set alongside them, so anyone picking an icon can bring
  # Font Awesome back.
  #
  # Every picker fills its grid from /svg-sprite/picker-search, which the server
  # builds from SvgSprite.picker_icon_ids. A theme can't change a server
  # response, and hiding icons in the browser breaks the picker's paging:
  # results come 100 at a time in alphabetical order and lucide-* falls in the
  # middle. So the list is filtered here. Nothing but the pickers calls
  # picker_icon_ids (checked on 2026.10.0), so the icons Discourse renders don't
  # change, and Font Awesome stays in the sprite for core UI.
  module LucideIconPickers
    PREFIX = "lucide-"

    def self.enabled?
      SiteSetting.cardwell_community_enabled && SiteSetting.cardwell_lucide_icon_pickers_enabled
    end

    # Filters after core's cached list rather than inside it, so a toggle
    # takes effect on the next request without expiring the sprite cache.
    module SvgSpriteExtension
      def picker_icon_ids(theme_id, only_available)
        ids = super
        return ids unless CardwellCommunity::LucideIconPickers.enabled?

        ids.select { |id| id.start_with?(CardwellCommunity::LucideIconPickers::PREFIX) }
      end
    end

    # The picker-search response is cached by ETag (core version, sprite
    # version, filter, only_available, page), none of which a toggle changes.
    # Adding the setting makes browsers refetch the list when it flips.
    # icon_picker_search is the only action in SvgSpriteController that calls
    # stale? (2026.10.0).
    module SvgSpriteControllerExtension
      def stale?(*args, **opts)
        if opts.key?(:etag)
          opts[:etag] = [opts[:etag], CardwellCommunity::LucideIconPickers.enabled?]
        end
        super
      end
    end
  end
end
