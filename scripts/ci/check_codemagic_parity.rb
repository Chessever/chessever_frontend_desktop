#!/usr/bin/env ruby
# Keep the desktop release recipe aligned with Codemagic while GitHub owns
# runner setup, secret isolation, approval, masking, and artifact retention.
require 'yaml'

ROOT = File.expand_path('../..', __dir__)
codemagic = YAML.load_file(File.join(ROOT, 'codemagic.yaml')).fetch('workflows')
release = YAML.load_file(File.join(ROOT, '.github/workflows/desktop-release.yml'))
master = YAML.load_file(File.join(ROOT, '.github/workflows/desktop-macos-flutter-master.yml'))

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

  flutter = steps.find { |step| step.fetch('uses', '').start_with?('subosito/flutter-action@') }
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
  next if id == 'preflight'
  verify(job['environment'] == 'release' && job['needs'] == 'preflight',
         "#{id} lost the production approval boundary")
  finished = job.fetch('steps').find { |step| step['name'] == 'Notify Telegram release finished' }
  verify(finished['if'] == 'always()' && finished['continue-on-error'] == true,
         "#{id} changed completion notification behavior")
end

[release, master].each do |workflow|
  events = workflow['on'] || workflow[true]
  verify(events.keys == ['workflow_dispatch'], 'a desktop workflow runs without manual dispatch')
  verify(workflow['permissions'] == { 'contents' => 'read' }, 'token permissions expanded')
  workflow.fetch('jobs').each_value do |job|
    job.fetch('steps').each do |step|
      next unless step['uses']
      verify(step['uses'].match?(/@[0-9a-f]{40}\z/), 'an action is not pinned to a full commit')
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
