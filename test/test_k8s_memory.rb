#!/usr/bin/env ruby
# Renders the scala-play-app k8s template with `pkl eval` and asserts the
# job-tier memory sizing: the request/limit, the heap-dump volume (which must
# track the heap so an OOM dump is never truncated), and the heap percentage.
require 'minitest/autorun'
require 'yaml'
require 'json'
require 'open3'

class TestK8sMemory < Minitest::Test
  K8S_DIR = File.expand_path('../k8s', __dir__)
  TEMPLATE = 'templates/scala-play-app.pkl'

  # Mirror generate-k8s.rb: read an app's jobMemory/webMemory from its pkl, then
  # render the shared template with those values. Returns the parsed StatefulSet
  # (job tier) container + heap-dump volume + JAVA_OPTS string.
  def render_job(app:, port:, extra_env: {})
    env = { 'APP' => app, 'PORT' => port.to_s, 'VERSION' => '0.0.1-test' }.merge(extra_env)
    out, err, status = Open3.capture3(env, 'pkl', 'eval', '-f', 'yaml', TEMPLATE, chdir: K8S_DIR)
    assert status.success?, "pkl eval failed: #{err}"
    docs = YAML.load_stream(out).compact
    ss = docs.find { |d| d['kind'] == 'StatefulSet' }
    refute_nil ss, 'no StatefulSet (job tier) in rendered manifest'
    container = ss.dig('spec', 'template', 'spec', 'containers').first
    heap_dump = ss.dig('spec', 'template', 'spec', 'volumes').find { |v| v['name'] == 'heap-dumps' }
    java_opts = container['env'].find { |e| e['name'] == 'JAVA_OPTS' }['value']
    { container: container, heap_dump: heap_dump, java_opts: java_opts }
  end

  def app_job_memory(app)
    out, err, status = Open3.capture3('pkl', 'eval', '-f', 'json', "apps/#{app}.pkl", chdir: K8S_DIR)
    assert status.success?, "pkl eval failed: #{err}"
    JSON.parse(out)['jobMemory']
  end

  # platform-job is right-sized to 6000Mi (4500MB heap at 75%); the heap-dump
  # volume must be heap * 1.2 = 5400Mi so a full OOM dump fits.
  def test_platform_job_is_right_sized
    job_memory = app_job_memory('platform')
    assert_equal '6000Mi', job_memory, 'platform.pkl jobMemory drifted'
    # Mirror k8s-deploy, which also forwards the app's javaAgent so the rendered
    # JAVA_OPTS is the real production New Relic path, not the no-agent variant.
    r = render_job(app: 'platform', port: 9300,
                   extra_env: { 'JOB_MEMORY' => job_memory, 'WEB_MEMORY' => '4400Mi',
                                'JAVA_AGENT' => '/opt/newrelic/newrelic.jar' })
    assert_equal '6000Mi', r[:container].dig('resources', 'requests', 'memory')
    assert_equal '6000Mi', r[:container].dig('resources', 'limits', 'memory')
    assert_equal '5400Mi', r[:heap_dump].dig('emptyDir', 'sizeLimit')
    assert_includes r[:java_opts], '-javaagent:/opt/newrelic/newrelic.jar'
    assert_includes r[:java_opts], '-XX:MaxRAMPercentage=75.0'
  end

  # An app that pins nothing inherits the template default; keep it a sane,
  # proven-schedulable footprint (not a per-app pipeline size).
  def test_template_default_job_memory
    r = render_job(app: 'testapp', port: 9999)
    assert_equal '5600Mi', r[:container].dig('resources', 'requests', 'memory')
    assert_equal '5040Mi', r[:heap_dump].dig('emptyDir', 'sizeLimit')
  end

  # Invariant: the heap-dump volume always tracks the heap (memory * ram% * 1.2),
  # rounded down to whole Mi, so it can never silently drift below the heap.
  def test_heap_dump_tracks_heap
    job_memory = app_job_memory('platform')
    mib = job_memory.delete_suffix('Mi').to_i
    expected = "#{mib * 75 / 100 * 12 / 10}Mi"
    r = render_job(app: 'platform', port: 9300, extra_env: { 'JOB_MEMORY' => job_memory, 'WEB_MEMORY' => '4400Mi' })
    assert_equal expected, r[:heap_dump].dig('emptyDir', 'sizeLimit')
  end
end
