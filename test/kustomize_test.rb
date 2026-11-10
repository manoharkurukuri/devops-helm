require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "uri"
require "yaml"

class KustomizeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ENVIRONMENTS = {
    "dev" => { namespace: "devops-app", ports: [30080, 31818] },
    "stage" => { namespace: "devops-app-stage", ports: [30081, 31819] },
    "prod" => { namespace: "devops-app-prod", ports: [30083, 31820] }
  }.freeze
  COMPONENTS = %w[backend frontend].freeze

  def self.command(*arguments)
    output, error, result = Open3.capture3(*arguments)
    raise "#{arguments.join(' ')} failed:\n#{error}" unless result.success?

    YAML.load_stream(output).compact
  end

  def self.render(root, path)
    command(ENV.fetch("KUSTOMIZE", "kustomize"), "build", File.join(root, path),
            "--enable-helm", "--helm-command", ENV.fetch("HELM", "helm"))
  end

  def setup
    @baseline = self.class.instance_variable_get(:@baseline)
    return if @baseline

    @baseline = ENVIRONMENTS.keys.to_h do |environment|
      [environment, self.class.render(ROOT, "kustomize/overlays/#{environment}")]
    end
    self.class.instance_variable_set(:@baseline, @baseline)
  end

  def resource(resources, kind, name)
    matches = resources.select do |item|
      item["kind"] == kind && item.dig("metadata", "name") == name
    end
    assert_equal 1, matches.length, "Expected one #{kind}/#{name}"
    matches.first
  end

  def identities(resources)
    resources.map do |item|
      [item.fetch("apiVersion"), item.fetch("kind"),
       item.dig("metadata", "namespace"), item.dig("metadata", "name")]
    end.sort
  end

  def with_fixture
    Dir.mktmpdir("notes-kustomize-test-") do |directory|
      %w[helm-notes-app kustomize kustomization.yaml].each do |entry|
        FileUtils.cp_r(File.join(ROOT, entry), directory)
      end
      yield directory
    end
  end

  def test_namespaces_images_and_workload_references
    @baseline.each do |environment, resources|
      expected = ENVIRONMENTS.fetch(environment)
      assert_equal 13, resources.length
      assert_equal identities(resources).uniq, identities(resources), "Duplicate resource IDs"
      assert_equal [expected.fetch(:namespace)], resources.map { |item| item.dig("metadata", "namespace") }.uniq
      overlay = YAML.load_file(File.join(ROOT, "kustomize/overlays/#{environment}/kustomization.yaml"))

      COMPONENTS.each do |component|
        name = "fullstack-#{component}"
        deployment = resource(resources, "Deployment", name)
        service = resource(resources, "Service", name)
        labels = deployment.dig("spec", "template", "metadata", "labels")
        service.fetch("spec").fetch("selector").each do |key, value|
          assert_equal value, labels.fetch(key)
        end
        deployment.dig("spec", "selector", "matchLabels").each do |key, value|
          assert_equal value, labels.fetch(key)
        end
        assert_equal 1, deployment.dig("spec", "replicas")
        container = deployment.dig("spec", "template", "spec", "containers").find { |item| item["name"] == component }
        container.fetch("envFrom").each do |reference|
          resource(resources, "ConfigMap", reference.fetch("configMapRef").fetch("name"))
        end
        repository = "mkurukuri/notes-#{component}"
        if environment == "dev"
          values = YAML.load_file(File.join(ROOT, "helm-notes-app/environments/dev/#{component}.yaml"))
          tag = values.fetch(component).fetch("image").fetch("tag")
          assert_equal({ component => { "image" => { "tag" => tag } } }, values,
                       "Dev CI inputs must remain image-tag-only")
          expected_image = "#{repository}:#{tag}"
        else
          pins = overlay.fetch("images").select { |image| image["name"] == repository }
          assert_equal 1, pins.length, "#{environment} must pin #{component}"
          pin = pins.first
          assert_equal 1, %w[newTag digest].count { |key| pin.key?(key) }
          if pin.key?("digest")
            assert_match(/\Asha256:[a-f0-9]{64}\z/, pin.fetch("digest"))
            expected_image = "#{repository}@#{pin.fetch('digest')}"
          else
            refute_includes [nil, "", "latest", "bootstrap"], pin["newTag"]
            expected_image = "#{repository}:#{pin.fetch('newTag')}"
          end
        end
        assert_equal expected_image, container.fetch("image")
        if component == "backend"
          %w[DB_URL JWT_SECRET].each do |key|
            secret = container.fetch("env").find { |item| item["name"] == key }.dig("valueFrom", "secretKeyRef")
            assert_equal({ "name" => "backend-secrets", "key" => key }, secret)
          end
        end
      end
    end
  end

  def test_gateway_ports_routing_tls_and_rollout_annotation
    allocated_ports = []
    @baseline.each do |environment, resources|
      expected = ENVIRONMENTS.fetch(environment)
      proxy = resource(resources, "EnvoyProxy", "fullstack-proxy")
      ports = proxy.dig("spec", "provider", "kubernetes", "envoyService", "patch", "value", "spec", "ports")
      assert_equal [80, 443], ports.map { |port| port.fetch("port") }
      assert_equal expected.fetch(:ports), ports.map { |port| port.fetch("nodePort") }
      allocated_ports.concat(ports.map { |port| port.fetch("nodePort") })
      config = resource(resources, "ConfigMap", "fullstack-frontend-config")
      endpoint = URI(config.dig("data", "API_URL"))
      assert_equal "https", endpoint.scheme
      assert_equal "/api", endpoint.path
      assert_equal expected.fetch(:ports).last, endpoint.port
      deployment = resource(resources, "Deployment", "fullstack-frontend")
      assert_equal endpoint.to_s, deployment.dig("spec", "template", "metadata", "annotations", "notes-app/config-api-url")

      certificate = resource(resources, "Certificate", "notes-app-certificate")
      assert_includes certificate.dig("spec", "ipAddresses"), endpoint.host
      resource(resources, "Issuer", certificate.dig("spec", "issuerRef", "name"))
      gateway = resource(resources, "Gateway", "fullstack-gateway")
      assert_equal "fullstack-proxy", gateway.dig("spec", "infrastructure", "parametersRef", "name")
      listeners = gateway.fetch("spec").fetch("listeners")
      assert_equal [80, 443], listeners.map { |listener| listener.fetch("port") }
      assert listeners.all? { |listener| listener.dig("allowedRoutes", "namespaces", "from") == "Same" }
      https = listeners.find { |listener| listener["protocol"] == "HTTPS" }
      assert_equal certificate.dig("spec", "secretName"), https.dig("tls", "certificateRefs", 0, "name")
      route = resource(resources, "HTTPRoute", "fullstack-route")
      route.fetch("spec").fetch("parentRefs").each do |reference|
        assert_equal "fullstack-gateway", reference.fetch("name")
        assert_includes listeners.map { |listener| listener.fetch("name") }, reference.fetch("sectionName")
      end
      rules = route.fetch("spec").fetch("rules")
      assert_equal ["/api/runtime-config", "/api/config"], rules.first.fetch("matches").map { |match| match.dig("path", "value") }
      assert_equal ["fullstack-frontend", "fullstack-backend", "fullstack-frontend"], rules.map { |rule| rule.dig("backendRefs", 0, "name") }
      assert_equal ["/api", "/"], rules.drop(1).map { |rule| rule.dig("matches", 0, "path", "value") }
      rules.each do |rule|
        rule.fetch("backendRefs").each do |reference|
          service = resource(resources, "Service", reference.fetch("name"))
          assert_includes service.dig("spec", "ports").map { |port| port.fetch("port") }, reference.fetch("port")
        end
      end
    end
    assert_equal allocated_ports.uniq, allocated_ports, "NodePorts must be unique cluster-wide"
    refute_includes allocated_ports, 30082
  end

  def test_dev_image_updates_do_not_promote_stage_or_prod
    with_fixture do |directory|
      COMPONENTS.each do |component|
        path = File.join(directory, "helm-notes-app/environments/dev/#{component}.yaml")
        File.write(path, YAML.dump(component => { "image" => { "tag" => "unpromoted-#{component}-test" } }))
      end
      %w[stage prod].each do |environment|
        assert_equal @baseline.fetch(environment), self.class.render(directory, "kustomize/overlays/#{environment}"),
                     "A dev image update changed #{environment}"
      end
      dev = self.class.render(directory, "kustomize/overlays/dev")
      COMPONENTS.each do |component|
        deployment = resource(dev, "Deployment", "fullstack-#{component}")
        assert_equal "mkurukuri/notes-#{component}:unpromoted-#{component}-test",
                     deployment.dig("spec", "template", "spec", "containers", 0, "image")
      end
    end
  end

  def test_frontend_config_changes_roll_pods_in_every_environment
    with_fixture do |directory|
      ENVIRONMENTS.each_key do |environment|
        path = File.join(directory, "kustomize/overlays/#{environment}/kustomization.yaml")
        overlay = YAML.load_file(path)
        generator = overlay.fetch("configMapGenerator").find { |item| item["name"] == "fullstack-frontend-config" }
        generator["literals"] = ["API_URL=https://192.168.252.13:31999/api"]
        File.write(path, YAML.dump(overlay))
        changed = self.class.render(directory, "kustomize/overlays/#{environment}")
        before = resource(@baseline.fetch(environment), "Deployment", "fullstack-frontend")
        after = resource(changed, "Deployment", "fullstack-frontend")
        refute_equal before.dig("spec", "template"), after.dig("spec", "template")
        assert_equal "https://192.168.252.13:31999/api",
                     after.dig("spec", "template", "metadata", "annotations", "notes-app/config-api-url")
        assert_equal identities(@baseline.fetch(environment)), identities(changed)
      end
    end
  end

  def test_root_is_dev_and_resource_names_match_direct_helm
    assert_equal @baseline.fetch("dev"), self.class.render(ROOT, ".")
    helm = self.class.command(ENV.fetch("HELM", "helm"), "template", "fullstack", File.join(ROOT, "helm-notes-app"),
                              "--namespace", "devops-app",
                              "-f", File.join(ROOT, "helm-notes-app/environments/dev/frontend.yaml"),
                              "-f", File.join(ROOT, "helm-notes-app/environments/dev/backend.yaml"))
    assert_equal identities(helm), identities(@baseline.fetch("dev"))
    COMPONENTS.each do |component|
      before = resource(helm, "Deployment", "fullstack-#{component}")
      after = resource(@baseline.fetch("dev"), "Deployment", "fullstack-#{component}")
      assert_equal before.dig("spec", "selector"), after.dig("spec", "selector")
    end
  end

  def test_argo_applications_use_matching_overlays
    ENVIRONMENTS.each do |environment, expected|
      suffix = environment == "dev" ? "" : "-#{environment}"
      application = YAML.load_file(File.join(ROOT, "bootstrap/argocd-application#{suffix}.yaml"))
      assert_equal "Application", application.fetch("kind")
      assert_equal "fullstack-#{environment}", application.dig("metadata", "name")
      assert_equal "argocd", application.dig("metadata", "namespace")
      assert_equal "kustomize/overlays/#{environment}", application.dig("spec", "source", "path")
      assert_equal "main", application.dig("spec", "source", "targetRevision")
      refute application.fetch("spec").fetch("source").key?("helm")
      assert_equal expected.fetch(:namespace), application.dig("spec", "destination", "namespace")
      assert_equal "https://kubernetes.default.svc", application.dig("spec", "destination", "server")
      assert_includes application.dig("spec", "syncPolicy", "syncOptions"), "CreateNamespace=true"
      assert_nil application.dig("spec", "syncPolicy", "automated") unless environment == "dev"
    end
    settings = YAML.load_file(File.join(ROOT, "bootstrap/argocd-values.yaml"))
    assert_equal "--enable-helm", settings.dig("configs", "cm", "kustomize.buildOptions")
  end
end