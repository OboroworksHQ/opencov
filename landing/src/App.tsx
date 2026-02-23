import logo from './assets/opencov-logo.svg'
import './App.css'

const highlights = [
  {
    title: 'Coverage history over time',
    text: 'Track project coverage across builds to spot regressions quickly.',
  },
  {
    title: 'Coveralls-compatible ingestion',
    text: 'Reuse existing coverage tooling with minimal setup changes.',
  },
  {
    title: 'Self-hosted and open source',
    text: 'Run inside your own infrastructure with full control of your data.',
  },
]

function App() {
  return (
    <main className="page">
      <section className="hero">
        <img src={logo} className="brand-logo" alt="OpenCov logo" />
        <p className="eyebrow">OpenCov</p>
        <h1>Self-hosted test coverage history viewer.</h1>
        <p className="lead">
          OpenCov helps teams monitor code coverage over time, review per-build
          details, and keep quality trends visible.
        </p>

        <div className="actions">
          <a
            className="btn btn-primary"
            href="https://github.com/danhper/opencov"
            target="_blank"
            rel="noreferrer"
          >
            View on GitHub
          </a>
          <a
            className="btn btn-secondary"
            href="http://demo.opencov.com"
            target="_blank"
            rel="noreferrer"
          >
            Open Demo
          </a>
        </div>
      </section>

      <section className="highlights" aria-label="Product highlights">
        {highlights.map((item) => (
          <article key={item.title} className="card">
            <h2>{item.title}</h2>
            <p>{item.text}</p>
          </article>
        ))}
      </section>
    </main>
  )
}

export default App
