# Engineering Example Repository

This is a template repository that should allow you to quickly create a new project repository that is already pre-configured with our patterns. This header should be removed and updated with your project description. A variant of the below setup tasks should be updated and included in your project README.

## Repository Setup

Unfortunately, github template repositories do not copy repository settings into the new repository. This means that you will still need to setup things like.

* Give access to:
	* portalarchitects/core: Admin
	* portalarchitects/developers: Write
	* portalarchitects/qa: Read
	* portalarchitects/services: Read
* Add a branch protection rule against the default branch
	* Require a pull request before merging
	* Require approvals
	* Require status checks to pass before merging
	* Include administrators
* Change options
	* Disable Wiki
	* Disable Issues
	* Disallow merge commits
	* Disallow rebase merging
	* Automatically delete head branches

## Local Development

Git Hooks are enabled on this repository. You will need to run `git config --local core.hooksPath .githooks/` to enable them on your environment. **You may want to add some configuration in your project to run this automatically. An example would be `preinstall` script that sets it up automatically**.
