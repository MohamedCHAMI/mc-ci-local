import XCTest
@testable import CILocal

final class WorkflowPatcherTests: XCTestCase {
    // Shape of chessvox's deploy.yml before it moved to the Mac runner.
    let deploy = """
    name: Deploy to Hostinger

    on:
      push:
        branches: [main]

    jobs:
      checks:
        uses: ./.github/workflows/ci.yml

      deploy:
        needs: checks
        runs-on: ubuntu-24.04
        steps:
          - name: Write .env
            run: |
              cat > .env <<'ENV_EOF'
              KEY=${{ secrets.KEY }}
              ENV_EOF
              sed -i 's/^ *//' .env

          - name: Deploy
            run: npm run hostinger:deploy

    """

    func testDeployWorkflowBecomesMacSafe() {
        let r = WorkflowPatcher.patch(deploy)
        XCTAssertTrue(r.text.contains("    runs-on: [self-hosted, mac-local]"))
        XCTAssertTrue(r.text.contains("sed -i.bak 's/^ *//' .env && rm -f .env.bak"))
        XCTAssertTrue(r.text.contains("      - name: Remove .env\n        if: always()\n        run: rm -f .env .env.bak"))
        // Cleanup lands at the end of the deploy job, after its last step.
        let deployStep = r.text.range(of: "npm run hostinger:deploy")!
        XCTAssertLessThan(deployStep.lowerBound, r.text.range(of: "- name: Remove .env")!.lowerBound)
        XCTAssertEqual(r.changes.count, 3)
        XCTAssertTrue(r.warnings.contains { $0.contains("Deploys with secrets") })
    }

    func testPatchingIsIdempotent() {
        let once = WorkflowPatcher.patch(deploy).text
        let twice = WorkflowPatcher.patch(once)
        XCTAssertFalse(twice.changed)
        XCTAssertEqual(twice.text, once)
    }

    func testRunsOnForms() {
        let yml = """
        jobs:
          a:
            runs-on: "ubuntu-latest"
          b:
            runs-on: [ubuntu-22.04]
          c:
            runs-on: macos-14
          d:
            runs-on: ${{ matrix.os }}
        """
        let r = WorkflowPatcher.patch(yml)
        XCTAssertEqual(r.text.components(separatedBy: "[self-hosted, mac-local]").count - 1, 2)
        XCTAssertTrue(r.text.contains("runs-on: macos-14"))
        XCTAssertTrue(r.warnings.contains { $0.contains("matrix") })
    }

    func testWarnsAboutLinuxOnlySteps() {
        let yml = """
        jobs:
          test:
            runs-on: ubuntu-latest
            services:
              postgres:
                image: postgres
            steps:
              - run: sudo apt-get install -y jq
        """
        let w = WorkflowPatcher.patch(yml).warnings.joined(separator: "\n")
        XCTAssertTrue(w.contains("apt"))
        XCTAssertTrue(w.contains("service containers"))
    }

    func testAlreadyCleanWorkflowIsUntouched() {
        let yml = """
        jobs:
          test:
            runs-on: [self-hosted, mac-local]
            steps:
              - run: npm test
        """
        let r = WorkflowPatcher.patch(yml)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.text, yml)
        XCTAssertTrue(r.warnings.isEmpty)
    }
}

final class FailureKindTests: XCTestCase {
    func testClassifiesGitHubAnnotations() {
        XCTAssertEqual(FailureKind.from(annotations: ["The job was not started because recent account payments have failed or your spending limit needs to be increased."]), .billing)
        XCTAssertEqual(FailureKind.from(annotations: ["The self-hosted runner lost communication with the server. Verify the machine is running."]), .runnerLost)
        XCTAssertEqual(FailureKind.from(annotations: ["Process completed with exit code 1."]), .code)
        XCTAssertEqual(FailureKind.from(annotations: []), .code)
    }
}
