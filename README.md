<br /><br />

<p align="center">
<a href="https://plane.so">
  <img src="https://media.docs.plane.so/logo/plane_github_readme.png" alt="Plane Logo" width="400">
</a>
</p>
<p align="center"><b>Modern project management for all teams</b></p>

<p align="center">
    <a href="https://plane.so/"><b>Website</b></a> •
    <a href="https://forum.plane.so"><b>Forum</b></a> •
    <a href="https://x.com/planepowers"><b>X</b></a> •
    <a href="https://docs.plane.so/"><b>Documentation</b></a>
</p>

<p>
    <a href="https://app.plane.so/#gh-light-mode-only" target="_blank">
      <img
        src="https://media.docs.plane.so/GitHub-readme/github-top.webp"
        alt="Plane Screens"
        width="100%"
      />
    </a>
</p>

Meet [Plane](https://plane.so/), an open-source project management tool to track issues, run ~sprints~ cycles, and manage product roadmaps without the chaos of managing the tool itself. 🧘‍♀️

> Plane is evolving every day. Your suggestions, ideas, and reported bugs help us immensely. Do not hesitate to join in the conversation on [Forum](https://forum.plane.so) or raise a GitHub issue. We read everything and respond to most.

## 🚀 Installation

Getting started with Plane is simple. Choose the setup that works best for you:

- **Plane Cloud**
  Sign up for a free account on [Plane Cloud](https://app.plane.so)—it's the fastest way to get up and running without worrying about infrastructure.

- **Self-host Plane**
  Prefer full control over your data and infrastructure? Install and run Plane on your own servers. Follow our detailed [deployment guides](https://developers.plane.so/self-hosting/overview) to get started.

- **Self-host without Docker**
  Run Plane as native `systemd` services on bare metal or a VM — see [deployments/systemd](./deployments/systemd/README.md).

| Installation methods | Docs link                                                                                                                                                                               |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Docker               | [![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://developers.plane.so/self-hosting/methods/docker-compose)         |
| Kubernetes           | [![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=for-the-badge&logo=kubernetes&logoColor=white)](https://developers.plane.so/self-hosting/methods/kubernetes) |
| All-in-one Docker    | [deployments/aio/community](./deployments/aio/community/README.md) · [docs](https://developers.plane.so/self-hosting/methods/docker-aio)                                                |
| systemd (no Docker)  | [deployments/systemd](./deployments/systemd/README.md)                                                                                                                                  |

### Self-hosting with systemd

`deployments/systemd/` contains everything needed to run Plane as native systemd units, with no
container runtime. The Docker files in this repo are left untouched, so both methods can coexist.

| Unit                     | Component                        | Local port |
| ------------------------ | -------------------------------- | ---------- |
| `plane-migrate.service`  | Django migrations (oneshot)      | –          |
| `plane-api.service`      | Django API (gunicorn + uvicorn)  | `8000`     |
| `plane-worker.service`   | Celery worker                    | –          |
| `plane-beat.service`     | Celery beat                      | –          |
| `plane-live.service`     | Realtime server (Hocuspocus)     | `3100`     |
| `plane-space.service`    | Space (public pages, SSR)        | `3202`     |
| `plane-web.service`      | Web frontend (static, Caddy)     | `3200`     |
| `plane-admin.service`    | God mode admin (static, Caddy)   | `3201`     |
| `plane-proxy.service`    | Reverse proxy + TLS (Caddy)      | `80/443`   |

Quick start on the target host (Ubuntu 22.04/24.04 or Debian 12):

```bash
# 1. Put the code in place and create the service user
sudo mkdir -p /opt/plane
sudo rsync -a --exclude node_modules --exclude .git ./ /opt/plane/
sudo useradd --system --home-dir /opt/plane --shell /usr/sbin/nologin plane
sudo chown -R plane:plane /opt/plane

# 2. Python deps (uv) and frontend build (Node >= 22.22 + pnpm)
#    VITE_* values are baked into the bundles at build time; empty *_BASE_URL keeps
#    the frontends same-origin behind the proxy.
sudo -u plane bash -lc 'cd /opt/plane/apps/api && uv sync --locked --no-default-groups --group production'
sudo -u plane bash -lc 'cd /opt/plane && pnpm install --frozen-lockfile \
  && VITE_ADMIN_BASE_PATH=/god-mode VITE_SPACE_BASE_PATH=/spaces VITE_LIVE_BASE_PATH=/live \
     pnpm turbo run build --filter=web --filter=admin --filter=space --filter=live'

# 3. Install units, Caddy configs and env templates
sudo bash /opt/plane/deployments/systemd/install.sh

# 4. Fill in secrets and URLs
sudoedit /etc/plane/api.env /etc/plane/live.env /etc/plane/proxy.env

# 5. Start everything
sudo systemctl daemon-reload
sudo systemctl enable --now plane-migrate plane-api plane-worker plane-beat \
  plane-live plane-space plane-web plane-admin plane-proxy
```

Each component reuses the existing entrypoints in `apps/api/bin/`, so production behaviour
matches the Docker images. Ports differ from the Docker setup because all services share the
host network namespace.

Operate it like any other unit:

```bash
systemctl status plane-api plane-worker plane-beat plane-live plane-space plane-web plane-admin plane-proxy
journalctl -u plane-api -f
journalctl -u plane-worker -f
journalctl -u plane-proxy -n 200
systemctl restart plane-api plane-worker plane-beat
```

See [deployments/systemd/README.md](./deployments/systemd/README.md) for prerequisites
(PostgreSQL, Redis/Valkey, RabbitMQ, object storage), configuration details, upgrades, and
troubleshooting.

`Instance admins` can configure instance settings with [God mode](https://developers.plane.so/self-hosting/govern/instance-admin).

## 🌟 Features

- **Work Items**
  Efficiently create and manage tasks with a robust rich text editor that supports file uploads. Enhance organization and tracking by adding sub-properties and referencing related issues.

- **Cycles**
  Maintain your team’s momentum with Cycles. Track progress effortlessly using burn-down charts and other insightful tools.

- **Modules**
  Simplify complex projects by dividing them into smaller, manageable modules.

- **Views**
  Customize your workflow by creating filters to display only the most relevant issues. Save and share these views with ease.

- **Pages**
  Capture and organize ideas using Plane Pages, complete with AI capabilities and a rich text editor. Format text, insert images, add hyperlinks, or convert your notes into actionable items.

- **Analytics**
  Access real-time insights across all your Plane data. Visualize trends, remove blockers, and keep your projects moving forward.

## 🛠️ Local development

See [CONTRIBUTING](./CONTRIBUTING.md)

## ⚙️ Built with

[![React Router](https://img.shields.io/badge/-React%20Router-CA4245?logo=react-router&style=for-the-badge&logoColor=white)](https://reactrouter.com/)
[![Django](https://img.shields.io/badge/Django-092E20?style=for-the-badge&logo=django&logoColor=green)](https://www.djangoproject.com/)
[![Node JS](https://img.shields.io/badge/node.js-339933?style=for-the-badge&logo=Node.js&logoColor=white)](https://nodejs.org/en)

## 📸 Screenshots

  <p>
    <a href="https://plane.so" target="_blank">
      <img
        src="https://media.docs.plane.so/GitHub-readme/github-work-items.webp"
        alt="Plane Views"
        width="100%"
      />
    </a>
  </p>
  <p>
    <a href="https://plane.so" target="_blank">
      <img
        src="https://media.docs.plane.so/GitHub-readme/github-cycles.webp"
        width="100%"
      />
    </a>
  </p>
  <p>
    <a href="https://plane.so" target="_blank">
      <img
        src="https://media.docs.plane.so/GitHub-readme/github-modules.webp"
        alt="Plane Cycles and Modules"
        width="100%"
      />
    </a>
  </p>
  <p>
    <a href="https://plane.so" target="_blank">
      <img
        src="https://media.docs.plane.so/GitHub-readme/github-views.webp"
        alt="Plane Analytics"
        width="100%"
      />
    </a>
  </p>
   <p>
    <a href="https://plane.so" target="_blank">
      <img
        src="https://media.docs.plane.so/GitHub-readme/github-analytics.webp"
        alt="Plane Pages"
        width="100%"
      />
    </a>
  </p>
</p>

## 📝 Documentation

Explore Plane's [product documentation](https://docs.plane.so/) and [developer documentation](https://developers.plane.so/) to learn about features, setup, and usage.

## ❤️ Community

Join the Plane community on our [Forum](https://forum.plane.so), and use [GitHub issues](https://github.com/makeplane/plane/issues) for bug reports and feature requests. We follow a [Code of conduct](./CODE_OF_CONDUCT.md) in all our community channels.

Feel free to ask questions, report bugs, participate in discussions, share ideas, request features, or showcase your projects. We’d love to hear from you!

## 🛡️ Security

If you discover a security vulnerability in Plane, please report it responsibly instead of opening a public issue. We take all legitimate reports seriously and will investigate them promptly. See [Security policy](./SECURITY.md) for more info.

To disclose any security issues, please [report them privately on GitHub](https://github.com/makeplane/plane/security/advisories/new) or email us at security@plane.so.

## 🤝 Contributing

There are many ways you can contribute to Plane:

- Report [bugs](https://github.com/makeplane/plane/issues/new?template=--bug-report.yaml) or submit [feature requests](https://github.com/makeplane/plane/issues/new?template=--feature-request.yaml).
- Review the [documentation](https://docs.plane.so/) and tell us on the [Forum](https://forum.plane.so) or in a GitHub issue where it is wrong or incomplete.
- Add or update [translations](./CONTRIBUTING.md#contributing-to-language-support).
- Talk or write about Plane or any other ecosystem integration and [let us know](https://forum.plane.so)!
- Show your support by upvoting [popular feature requests](https://github.com/makeplane/plane/issues).

Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for details on the process for submitting pull requests to us.

### Repo activity

![Plane Repo Activity](https://repobeats.axiom.co/api/embed/2523c6ed2f77c082b7908c33e2ab208981d76c39.svg "Repobeats analytics image")

### We couldn't have done this without you.

<a href="https://github.com/makeplane/plane/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=makeplane/plane" />
</a>

## License

This project is licensed under the [GNU Affero General Public License v3.0](./LICENSE.txt).
