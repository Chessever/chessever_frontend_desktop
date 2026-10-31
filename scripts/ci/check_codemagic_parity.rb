#!/usr/bin/env ruby
# Keep the desktop release recipe aligned with Codemagic while GitHub owns
# runner setup, secret isolation, approval, masking, and artifact retention.
require 'yaml'

ROOT = File.expand_path('../..', __dir__)
codemagic = YAML.load_file(File.join(ROOT, 'codemagic.yaml')).fetch('workflows')
release = YAML.load_file(File.join(ROOT, '.github/workflows/desktop-release.yml'))
master = YAML.load_file(File.join(ROOT, '.github/workflows/desktop-macos-flutter-master.yml'))
store = YAML.load_file(File.join(ROOT, '.github/workflows/desktop-app-store.yml'))

def verify(condition, message)
  abort "Desktop workflow parity failed: #{message}" unless condition
end

def body(steps, key)
  steps.map { |step| step.fetch(key, '') }.join("\n")
end

recipes = {
  'macos-desktop-release-arm64' => 'macos',
  'macos-desktop-release-x64' => 'macos',
  'windows-desktop-release' => 'windows',
  'linux-desktop-release' => 'linux',
  'macos-desktop-master' => 'build'
}

recipes.each do |source_id, job_id|
  source = codemagic.fetch(source_id)
  workflow = source_id == 'macos-desktop-master' ? master : release
  job = workflow.fetch('jobs').fetch(job_id)
  steps = job.fetch('steps')
  source_steps = source.fetch('scripts') + source.fetch('publishing', {}).fetch('scripts', [])
  source_names = source_steps.map { |step| step.fetch('name') }
  target_names = steps.map { |step| step['name'] }
  aliases = {
    'Initialize keychain and install Developer ID certificate' => 'Install Developer ID certificate',
    'Build and publish Apple Silicon package' => 'Build and publish macOS package',
    'Build and publish Intel package' => 'Build and publish macOS package',
    'Mark macOS arm64 release succeeded' => 'Mark macOS release succeeded',
    'Mark macOS intel release succeeded' => 'Mark macOS release succeeded'
  }
  if job_id == 'macos'
    aliases['Install R2 publisher dependencies'] = 'Install R2 publisher and Codemagic CLI tools'
  end
  positions = source_names.map do |name|
    target = aliases.fetch(name, name)
    index = target_names.index(target)
    verify(!index.nil?, "#{source_id} lost #{name}")
    index
  end
  verify(positions == positions.sort, "#{source_id} changed the release step order")

  flutter = steps.find { |step| step['uses'] == './.github/actions/setup-flutter' }
  verify(flutter.fetch('with').fetch('channel') == source.fetch('environment').fetch('flutter'),
         "#{source_id} changed Flutter channel")
  source_body = body(source_steps, 'script')
  target_body = body(steps, 'run')
  verify(source_body.include?('flutter pub get') && target_body.include?('flutter pub get'),
         "#{source_id} lost package resolution")

  scripts = source_body.scan(%r{scripts[/\\](\w+\.(?:sh|ps1))}).flatten.uniq
  scripts.each do |script|
    verify(target_body.include?(script), "#{source_id} stopped using #{script}")
  end
  if job_id == 'macos' || job_id == 'build'
    %w[SUPABASE_URL SUPABASE_ANON_KEY GOOGLE_DESKTOP_CLIENT_ID
       GOOGLE_DESKTOP_CLIENT_SECRET SENTRY_FLUTTER CHESSEVER_CLOUDFLARE_API_BASE
       ANALYSIS_API_BASE].each do |name|
      verify(source_body.include?("--dart-define=#{name}=") &&
             target_body.include?("--dart-define=#{name}="),
             "#{source_id} changed #{name} build wiring")
    end
    verify(target_body.include?('pod install'), "#{source_id} lost CocoaPods")
  end

  background = steps.select { |step| step['background'] }
  verify(!background.empty?, "#{source_id} lost parallel toolchain setup")
  verify(steps.any? { |step| step.key?('wait-all') }, "#{source_id} lost setup synchronization")
  background.each do |step|
    verify(step.fetch('env', {}).values.none? { |value| value.to_s.include?('secrets.') },
           "#{source_id} passes credentials to background setup")
  end
  puts "#{source_id}: release sequence, scripts, toolchain and build inputs match"
end

release.fetch('jobs').each do |id, job|
  next if id == 'preflight' || id == 'telegram'
  verify(job['environment'] == 'release' && job['needs'] == 'preflight',
         "#{id} lost the production approval boundary")
  finished = job.fetch('steps').find { |step| step['name'] == 'Notify Telegram release finished' }
  verify(finished['if'] == 'always()' && finished['continue-on-error'] == true,
         "#{id} changed completion notification behavior")
end

[release, master, store].each do |workflow|
  events = workflow['on'] || workflow[true]
  verify(events.keys == ['workflow_dispatch'], 'a desktop workflow runs without manual dispatch')
  verify(workflow['permissions'] == { 'contents' => 'read' }, 'token permissions expanded')
  workflow.fetch('jobs').each_value do |job|
    job.fetch('steps').each do |step|
      next unless step['uses']
      verify(step['uses'] == './.github/actions/setup-flutter' ||
             step['uses'].match?(/@[0-9a-f]{40}\z/), 'an action is not pinned to a full commit')
      if step['uses'].start_with?('actions/checkout@')
        verify(step.fetch('with')['persist-credentials'] == false, 'checkout persists credentials')
      end
    end
  end
end

macos = release.fetch('jobs').fetch('macos')
verify(macos.fetch('strategy').fetch('matrix').fetch('arch') == %w[arm64 x64],
       'a macOS architecture is missing')
verify(macos.fetch('env').fetch('UPDATER_SLUG') ==
       "${{ matrix.arch == 'arm64' && 'macos' || 'macos-x64' }}",
       'the frozen Apple Silicon updater name changed')
verify(body(master.fetch('jobs').fetch('build').fetch('steps'), 'run').include?(
         'export FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO'),
       'the Flutter master build became signed')
puts 'All five desktop Codemagic recipes and GitHub release safeguards verified.'

store_job = store.fetch('jobs').fetch('mac_app_store')
verify(store_job['environment'] == 'release' && store_job['needs'] == 'preflight',
       'the Mac App Store lane lost production approval')
store_steps = store_job.fetch('steps')
verify(store_steps.count { |step| step['background'] } == 3 &&
       store_steps.any? { |step| step.key?('wait-all') }, 'store toolchains are not parallel')
# The signing job and preflight never see direct-download or chat credentials;
# only the separate Telegram updates job reads the organization TELEGRAM_* pair.
store.fetch('jobs').each do |id, job|
  next if id == 'telegram'
  verify(!job.to_s.match?(/secrets\.(?:R2_|TELEGRAM_|MACOS_DEVELOPER_ID)/),
         'direct-download credentials entered the store lane')
end
# Telegram updates: outside every environment, after nothing, read-only token,
# and only the organization chat pair plus the run's own token.
[release, master, store].each do |workflow|
  telegram = workflow.fetch('jobs').fetch('telegram')
  verify(!telegram.key?('environment') && !telegram.key?('needs'),
         'Telegram updates gained an environment or a dependency')
  verify(telegram['permissions'] == { 'contents' => 'read', 'actions' => 'read' },
         'Telegram updates token permissions expanded')
  secrets = telegram.to_s.scan(/secrets\.(\w+)/).flatten.uniq.sort
  verify(secrets == %w[TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID],
         "Telegram updates reads unexpected secrets: #{secrets.join(', ')}")
  verify(telegram.fetch('steps').all? { |step| step['uses'] || step['continue-on-error'] == true },
         'a Telegram update can fail the run')
end
store_build = File.read(File.join(ROOT, 'scripts/build_mac_app_store.sh'))
verify(store_build.include?('--dart-define=MAC_APP_STORE=true') &&
       store_build.include?('CHESSEVER_APP_STORE=YES'), 'store billing/native flags diverged')
store_submit = File.read(File.join(ROOT, 'scripts/ci/mac_app_store_submit.sh'))
verify(store_submit.include?('--platform MAC_OS --release-type MANUAL') &&
       !store_submit.include?('AFTER_APPROVAL'), 'store review can release automatically')
puts 'Mac App Store edition, signing separation and manual release verified.'
store_events = store['on'] || store[true]
store_inputs = store_events.fetch('workflow_dispatch').fetch('inputs')
verify(store_inputs.fetch('prepare_review_only').fetch('default') == true,
       'the first subscription review lost its explicit preparation handoff')
store_audit = store_steps.index { |step| step['name'] == 'Read-only App Store metadata preflight' }
store_build_index = store_steps.index { |step| step['name'] == 'Build and sign the universal store edition' }
verify(!store_audit.nil? && store_audit < store_build_index &&
       store_steps[store_audit].fetch('run').include?('mac_app_store_preflight.py --phase before-upload'),
       'store metadata/readiness preflight no longer precedes the build')
store_upload = store_steps.find { |step| step['name'] == 'Upload and optionally submit for manual release' }
verify(store_upload.fetch('env').fetch('PREPARE_REVIEW_ONLY') ==
       '${{ inputs.submit_review && inputs.prepare_review_only }}',
       'the review preparation choice is not wired to submission')
verify(store_submit.include?('--prepare-only') &&
       File.read(File.join(ROOT, 'scripts/ci/app_store_review.py')).include?('submit_mac('),
       'the Mac lane bypasses the subscription-preserving review path')
puts 'Mac review metadata/readiness preflight and first-subscription handoff verified.'
flutter_setup = YAML.load_file(File.join(ROOT, '.github/actions/setup-flutter/action.yaml'))
flutter_setup.fetch('runs').fetch('steps').each do |step|
  next unless step['uses']
  verify(step['uses'].match?(/@[0-9a-f]{40}\z/), 'Flutter setup contains an unpinned nested action')
end
