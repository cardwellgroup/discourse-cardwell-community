# frozen_string_literal: true

RSpec.describe CardwellCommunity::CompileTimeout do
  # The plugin's after_initialize already applied the default to this process
  # at boot, so every example starts from core's limit on purpose. An `around`
  # rather than before/after: rspec runs `after` hooks before it tears down
  # mocks, so an example that hides the constant or makes the setter raise
  # would make a plain `after` fail.
  around do |example|
    AssetProcessor.timeout = described_class.core_default_ms
    example.run
    AssetProcessor.timeout = described_class.core_default_ms
  end

  # Keep this plugin's broadcasts off the in-memory bus. The plugin's own
  # subscriber from after_initialize runs on another thread, and a delivery
  # landing in a later example would change the value under it. An example
  # that stubs publish itself opts out so the two stubs cannot interact.
  before do |example|
    next if example.metadata[:stubs_publish]
    allow(MessageBus).to receive(:publish).and_call_original
    allow(MessageBus).to receive(:publish).with(described_class::CHANNEL, anything, anything)
  end

  it "records core's default before changing it" do
    expect(described_class.core_default_ms).to eq(15_000)
  end

  it "applies the configured seconds to this process only, without broadcasting" do
    allow(described_class).to receive(:broadcast!)
    SiteSetting.cardwell_theme_compile_timeout_seconds = 20
    expect(AssetProcessor.timeout).to eq(15_000)

    described_class.apply!

    expect(AssetProcessor.timeout).to eq(20_000)
    expect(MessageBus).not_to have_received(:publish).with(described_class::CHANNEL, any_args)
  end

  it "puts the database's value on the channel at boot" do
    # Every in-example publish on the channel is stubbed away, so the memory
    # backend holds only what after_initialize published: the default, 24 s.
    # (rails_helper resets the memory backend after each system spec; this
    # plugin has none. If it ever does, this example becomes order-dependent.)
    expect(MessageBus.last_message(described_class::CHANNEL)&.data).to eq({ "ms" => 24_000 })
  end

  it "rebuilds the sandbox only when the limit changes" do
    SiteSetting.cardwell_theme_compile_timeout_seconds = 20

    # The limit is passed to MiniRacer::Context.new, so a context built under
    # the old limit keeps it until it is disposed; an unchanged limit must not
    # throw away a warm context.
    allow(AssetProcessor).to receive(:reset_context).and_call_original
    described_class.apply!
    expect(AssetProcessor).not_to have_received(:reset_context)

    SiteSetting.cardwell_theme_compile_timeout_seconds = 22
    expect(AssetProcessor).to have_received(:reset_context).once
    expect(AssetProcessor.timeout).to eq(22_000)
  end

  it "applies a setting change here and broadcasts it with a long backlog age" do
    SiteSetting.cardwell_theme_compile_timeout_seconds = 21

    expect(AssetProcessor.timeout).to eq(21_000)
    expect(MessageBus).to have_received(:publish).with(
      described_class::CHANNEL,
      { "ms" => 21_000 },
      max_backlog_age: described_class::BACKLOG_AGE_SECONDS,
    )
  end

  it "applies a received broadcast" do
    expect(described_class.receive({ "ms" => 21_000 })).to eq(true)

    expect(AssetProcessor.timeout).to eq(21_000)
  end

  it "ignores a malformed broadcast" do
    expect(described_class.receive("ms=21000")).to eq(false)
    expect(described_class.receive({ "ms" => nil })).to eq(false)
    expect(described_class.receive({ "ms" => -1 })).to eq(false)
    expect(described_class.receive({ "ms" => { "nested" => 1 } })).to eq(false)
    expect(described_class.receive(nil)).to eq(false)

    expect(AssetProcessor.timeout).to eq(15_000)
  end

  it "restores core's limit when the plugin is turned off, everywhere" do
    SiteSetting.cardwell_theme_compile_timeout_seconds = 20

    SiteSetting.cardwell_community_enabled = false

    expect(AssetProcessor.timeout).to eq(15_000)
    expect(MessageBus).to have_received(:publish).with(
      described_class::CHANNEL,
      { "ms" => 15_000 },
      anything,
    )
  end

  it "ignores unrelated setting changes" do
    AssetProcessor.timeout = 18_000

    SiteSetting.title = "Unrelated"

    expect(AssetProcessor.timeout).to eq(18_000)
  end

  describe ".resync!" do
    it "applies the channel's last broadcast in a freshly forked web worker" do
      allow(MessageBus).to receive(:last_message).with(described_class::CHANNEL).and_return(
        instance_double(MessageBus::Message, data: { "ms" => 19_000 }),
      )

      described_class.resync!

      expect(AssetProcessor.timeout).to eq(19_000)
    end

    it "falls back to the settings it can see when the channel holds nothing usable" do
      allow(MessageBus).to receive(:last_message).with(described_class::CHANNEL).and_return(
        nil,
        instance_double(MessageBus::Message, data: "garbage"),
      )
      SiteSetting.cardwell_theme_compile_timeout_seconds = 23

      AssetProcessor.timeout = 15_000
      described_class.resync!
      expect(AssetProcessor.timeout).to eq(23_000)

      AssetProcessor.timeout = 15_000
      described_class.resync!
      expect(AssetProcessor.timeout).to eq(23_000)
    end

    it "logs instead of raising when the bus is unavailable" do
      allow(MessageBus).to receive(:last_message).and_raise(RuntimeError, "redis down")
      allow(Rails.logger).to receive(:warn)

      expect { described_class.resync! }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/could not resync/)
    end
  end

  describe "process hooks" do
    # Nothing in core or the bundled plugins listens to these three events, so
    # triggering them here reaches only this plugin.
    it "resync a web worker and re-read settings in Sidekiq, even with the plugin off" do
      SiteSetting.cardwell_community_enabled = false
      allow(described_class).to receive(:resync!)
      allow(described_class).to receive(:apply!)

      DiscourseEvent.trigger(:web_fork_started)
      DiscourseEvent.trigger(:sidekiq_fork_started)

      expect(described_class).to have_received(:resync!).once
      expect(described_class).to have_received(:apply!).once
    end

    it "rebroadcast after an in-place backup restore, even with the plugin off" do
      SiteSetting.cardwell_community_enabled = false
      allow(described_class).to receive(:broadcast!)

      DiscourseEvent.trigger(:site_settings_restored)

      expect(described_class).to have_received(:broadcast!).once
    end
  end

  it "leaves core alone if AssetProcessor stops exposing the setter" do
    allow(AssetProcessor).to receive(:respond_to?).and_call_original
    allow(AssetProcessor).to receive(:respond_to?).with(:timeout=).and_return(false)
    allow(Rails.logger).to receive(:warn)

    expect { described_class.apply_ms!(20_000) }.not_to raise_error
    expect(AssetProcessor.timeout).to eq(15_000)
    expect(Rails.logger).to have_received(:warn).with(/compile limit left as is/)
  end

  it "leaves core alone if AssetProcessor stops exposing the mutex" do
    allow(AssetProcessor).to receive(:respond_to?).and_call_original
    allow(AssetProcessor).to receive(:respond_to?).with(:mutex).and_return(false)

    expect { described_class.apply_ms!(20_000) }.not_to raise_error
    expect(AssetProcessor.timeout).to eq(15_000)
  end

  it "does not raise at boot if the AssetProcessor constant is gone" do
    hide_const("AssetProcessor")
    allow(Rails.logger).to receive(:warn)

    expect { described_class.apply_ms!(20_000) }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).with(/compile limit left as is/)
  end

  it "logs instead of raising when the setter fails" do
    allow(AssetProcessor).to receive(:timeout=).and_raise(RuntimeError, "disposed")
    allow(Rails.logger).to receive(:warn)

    expect { described_class.apply_ms!(20_000) }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).with(/could not set the compile limit/)
  end

  it "logs instead of failing the admin's save when the broadcast fails", :stubs_publish do
    # Only this plugin's channel fails: the save itself publishes on core's
    # channels first (Site.clear_anon_cache!), and those have to keep working.
    allow(MessageBus).to receive(:publish).and_wrap_original do |original, channel, *rest|
      raise "redis down" if channel == described_class::CHANNEL
      original.call(channel, *rest)
    end
    allow(Rails.logger).to receive(:warn)

    expect { SiteSetting.cardwell_theme_compile_timeout_seconds = 20 }.not_to raise_error
    expect(AssetProcessor.timeout).to eq(20_000)
    expect(Rails.logger).to have_received(:warn).with(/could not broadcast/)
  end
end
