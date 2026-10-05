# 0. Install
# 1. A quiet database: the tree is empty
# 2. Build the incident
# 3. lock_tree_text(): the queue, top to bottom
# 4. lock_tree: who blocks whom, and for how long
# 5. lock_tree_roots(): the one session to act on
# 6. What the operator reads, and what they run
# 7. Bonus: a deadlock has no head of the queue
# 8. Bonus: what it looked like while you were not looking
# 9. Cleanup
