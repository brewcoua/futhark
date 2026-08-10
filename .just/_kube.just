import '_common.just'

# Written by the k8s_cluster role. Absolute, because a recipe may cd elsewhere:
# justfile_directory() is the root justfile's directory even inside a submodule, where
# module_directory() would give .just/.
#
# Exported here rather than in _common.just so it reaches only the modules that drive the
# cluster — ansible's own playbooks must not inherit a kubeconfig they did not ask for.
export KUBECONFIG := justfile_directory() / 'ansible/.generated/kubeconfig'
