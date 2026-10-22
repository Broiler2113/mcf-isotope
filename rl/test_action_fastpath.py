"""Forced opponent actions skip inference; learner values remain unchanged."""
import unittest
from collections import Counter
from unittest.mock import patch

import numpy as np
import torch

import train
from model import PolicyNet
from test_rl import fake_obs, legal_move


class ActionFastpathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def test_single_action_needs_neither_observation_nor_model(self):
        timings = Counter()
        with patch.object(train, "encode", side_effect=AssertionError("encoded forced action")):
            actions = train.choose_actions(None, [{"legal": [{"i": {"t": "end"}}]}] * 4,
                                           timings=timings)
        np.testing.assert_array_equal(actions, [0, 0, 0, 0])
        self.assertEqual(timings["forced_actions"], 4)
        self.assertEqual(timings["inference_secs"], 0)

    def test_mixed_batch_keeps_order_and_greedy_decisions(self):
        torch.manual_seed(14)
        net = PolicyNet()
        responses = [dict(obs=fake_obs(), legal=[legal_move(5, 7, 6 + j, 7) for j in range(n)])
                     for n in [1, 3, 1, 4]]
        expected = train.choose(net, [train.encode(r) for r in responses], "cpu", greedy=True)[0]
        actual = train.choose_actions(net, responses, greedy=True)
        np.testing.assert_array_equal(actual, expected)

    def test_stochastic_decisions_still_use_the_policy(self):
        responses = [{"legal": [1]}, {"legal": [1, 2, 3]}, {"legal": [1]}]
        with patch.object(train, "encode", return_value="encoded") as encode, patch.object(
                train, "choose", return_value=(np.asarray([2]), None, None)) as choose:
            actual = train.choose_actions("net", responses)
        np.testing.assert_array_equal(actual, [0, 2, 0])
        encode.assert_called_once_with(responses[1])
        choose.assert_called_once_with("net", ["encoded"], "cpu", greedy=False)

    def test_learner_single_action_still_computes_value(self):
        net = PolicyNet()
        with torch.no_grad():
            net.value[-1].weight.zero_()
            net.value[-1].bias.fill_(2.5)
        response = dict(obs=fake_obs(), legal=[legal_move(5, 7, 6, 7)])
        actions, logps, values = train.choose(net, [train.encode(response)], "cpu")
        self.assertEqual(actions[0], 0)
        self.assertAlmostEqual(logps[0], 0)
        self.assertAlmostEqual(values[0], 2.5)


if __name__ == "__main__":
    unittest.main()
